module StandardId
  # Garbage-collects dynamically registered clients (RFC 7591) that never
  # amounted to anything, and deregistered ones.
  #
  # Open registration is unauthenticated, so bots and abandoned connectors
  # accumulate ClientApplication rows. A client is reaped when it was
  # registered more than `stale_after_seconds` ago and EITHER
  #
  #   * it was deregistered (RFC 7592 DELETE deactivates; see
  #     ClientRegistration.deregister) more than the window ago — the row is
  #     what lets refresh and introspection say "gone" meanwhile, or
  #   * nobody ever used it: it is consent-gated (a completed authorization
  #     records a ClientGrant; a client registered with `require_consent:
  #     false` pinned never gets one, so it is only ever reaped once
  #     deregistered), and it has no ClientGrant, no AuthorizationCode in any
  #     state and no refresh token in any state. Consumed codes and dead
  #     refresh tokens count as use on purpose: they are what an active client
  #     leaves behind between authorizations, and the cleanup jobs delete them
  #     on their own schedule.
  #
  # The grace window is what lets a client register now and complete consent
  # days later. Only clients created through dynamic registration are ever
  # touched (migration 20261020120000 marks them); the job is a no-op before
  # that migration has run.
  class PurgeStaleDynamicClientsJob < ApplicationJob
    queue_as :default

    # @param stale_after_seconds [Integer] registered longer ago than this
    # @param batch_size [Integer] rows per batch
    # @return [Integer] clients deleted
    def perform(stale_after_seconds: 7.days.to_i, batch_size: 100)
      return 0 unless StandardId::ClientApplication.registration_management_column?

      cutoff = stale_after_seconds.seconds.ago
      deleted = 0
      stale_clients(cutoff).find_each(batch_size: batch_size) do |client|
        StandardId::ClientApplication.transaction do
          if StandardId::RefreshToken.client_binding_column?
            client.refresh_tokens.where(revoked_at: nil).update_all(revoked_at: Time.current)
          end
          # The dependent-destroy cascade lazy-loads the client's secrets and
          # codes, which a host running strict_loading_by_default would refuse.
          client.strict_loading!(false)
          client.destroy!
        end
        deleted += 1
      end
      Rails.logger.info("[StandardId] Purged #{deleted} stale dynamically registered clients older than #{cutoff}")
      deleted
    end

    private

    def stale_clients(cutoff)
      base = StandardId::ClientApplication.dynamically_registered.where("created_at < ?", cutoff)

      # A deregistered client only ever goes through the deactivated branch,
      # whatever it did or did not do while live.
      never_used = base
        .where(active: true, require_consent: true)
        .where.not(client_id: StandardId::ClientGrant.select(:client_id))
        .where.not(client_id: StandardId::AuthorizationCode.select(:client_id))
      if StandardId::RefreshToken.client_binding_column?
        never_used = never_used.where.not(id: StandardId::RefreshToken.where.not(client_application_id: nil).select(:client_application_id))
      end

      base.where(active: false).where("deactivated_at < ?", cutoff).or(never_used)
    end
  end
end
