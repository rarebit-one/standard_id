module StandardId
  # Deletes email + password sign-ups (StandardId::EmailPassword) that were
  # never verified. A no-op unless `c.email_password.enabled`; not part of
  # CleanupAllJob, so schedule it yourself (daily is plenty).
  #
  # A sign-up that sits unverified is dead weight at best and, at worst, a
  # stranger squatting someone else's address (see
  # EmailPassword::Registration). After `c.email_password.unverified_purge_after`
  # seconds (3 days by default, far beyond the code TTL and the daily code cap)
  # the pending password credential and its email identifier are removed, and
  # the account too when nothing else is left on it.
  #
  # Only an email identifier that is unverified, has no provider, carries a
  # password credential, is older than the cutoff AND has had a code issued in
  # `c.email_password.verification_realm` (the mark of a sign-up made through
  # EmailPassword::Registration) is considered. That last condition keeps the
  # job away from other unverified password sign-ups, such as
  # Web::SignupForm's, which never get a code in that realm. Unused code
  # challenges survive CleanupExpiredCodeChallengesJob for 7 days past expiry,
  # so keep `unverified_purge_after` well under that: a sign-up whose
  # challenge has already been cleaned up is simply never purged (fails safe).
  # Even then the whole account is skipped, unchanged, at any sign of real use:
  #   * any verified identifier, or any with a provider (a social sign-in
  #     linked to it does not verify the identifier, so the provider is
  #     checked separately);
  #   * any session or refresh token;
  #   * `c.email_password.account_in_use` returning true (e.g. the host's
  #     profile rows);
  #   * any other row still referencing the account: the delete is guarded by
  #     restrict / foreign keys, and a guard failure rolls the unit back.
  # A sign-up whose owner asked for a code within
  # `c.email_password.purge_recent_code_window` seconds is kept, so someone
  # who comes back on day 4 is not deleted minutes before typing the code in.
  # Each sign-up is re-checked under a row lock in its own transaction, so a
  # verification that lands mid-run wins.
  class PurgeUnverifiedEmailSignupsJob < ApplicationJob
    queue_as :default

    # @param older_than_seconds [Integer, nil] defaults to
    #   c.email_password.unverified_purge_after
    # @return [Hash] `{ purged_count:, skipped_count: }`
    def perform(older_than_seconds: nil)
      return { purged_count: 0, skipped_count: 0 } unless StandardId::EmailPassword.enabled?

      cutoff = (older_than_seconds || config.unverified_purge_after).to_i.seconds.ago
      purged = 0
      skipped = 0

      candidates(cutoff).find_each do |identifier|
        if purge(identifier, cutoff)
          purged += 1
        else
          skipped += 1
        end
      end

      Rails.logger.info("[StandardId] Purged #{purged} unverified email sign-ups older than #{cutoff} (skipped #{skipped})")
      { purged_count: purged, skipped_count: skipped }
    end

    private

    def config
      StandardId::EmailPassword.config
    end

    def candidates(cutoff)
      StandardId::EmailIdentifier
        .where(verified_at: nil, provider: nil)
        .where(created_at: ...cutoff)
        .where(id: StandardId::Credential.where(credentialable_type: StandardId::PasswordCredential.name).select(:identifier_id))
        .where(value: StandardId::CodeChallenge.where(realm: config.verification_realm, channel: "email").select(:target))
    end

    # true when the sign-up was removed, false when it was left alone.
    def purge(identifier, cutoff)
      ActiveRecord::Base.transaction do
        identifier.lock!
        return false unless identifier.verified_at.nil? && identifier.provider.nil? && identifier.created_at < cutoff

        account = StandardId.account_class.find_by(id: identifier.account_id)
        return false if account.nil? || account_in_use?(account)
        return false if recent_code_requested?(identifier.value)

        credentials = StandardId::Credential.where(identifier_id: identifier.id).to_a
        return false unless credentials.all? { |c| c.credentialable_type == StandardId::PasswordCredential.name }

        password_credentials = StandardId::PasswordCredential.where(id: credentials.map(&:credentialable_id)).to_a
        credentials.each(&:destroy!)
        password_credentials.each(&:destroy!)
        identifier.destroy!

        unless StandardId::Identifier.exists?(account_id: account.id)
          # The dependent-destroy cascade lazy-loads associations, which a host
          # running strict_loading_by_default would refuse.
          account.strict_loading!(false)
          account.destroy!
        end
        true
      end
    rescue ActiveRecord::DeleteRestrictionError, ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotDestroyed => e
      Rails.logger.warn("[StandardId] Left unverified email sign-up #{identifier.id} alone: #{e.class}")
      false
    end

    def account_in_use?(account)
      return true if StandardId::Identifier.where(account_id: account.id).where("verified_at IS NOT NULL OR provider IS NOT NULL").exists?
      return true if StandardId::Session.where(account_id: account.id).exists?
      return true if StandardId::RefreshToken.where(account_id: account.id).exists?

      hook = config.account_in_use
      # Any truthy answer keeps the account: when in doubt, keep.
      hook.respond_to?(:call) && StandardId::EmailPassword.call_hook(hook, account: account) ? true : false
    end

    def recent_code_requested?(email)
      StandardId::CodeChallenge
        .where(realm: config.verification_realm, target: StandardId::EmailPassword.normalize_email(email))
        .where(created_at: config.purge_recent_code_window.to_i.seconds.ago..)
        .exists?
    end
  end
end
