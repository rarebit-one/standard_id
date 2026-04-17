module StandardId
  module Api
    module Oauth
      class RevocationsController < BaseController
        public_controller

        skip_before_action :validate_content_type!

        # POST /oauth/revoke
        # RFC 7009 - OAuth 2.0 Token Revocation
        #
        # Accepts a token and optional token_type_hint parameter.
        # Always responds with 200 OK regardless of whether the token
        # was valid or revocation was successful (per RFC 7009 Section 2.1).
        def create
          token = params[:token]
          head :ok and return if token.blank?

          payload = StandardId::JwtService.decode(token)
          head :ok and return unless payload&.dig(:sub)

          account_id = payload[:sub]

          sessions = StandardId::DeviceSession
            .where(account_id: account_id)
            .active

          # token_type_hint is accepted but ignored — we always attempt
          # revocation via sub claim regardless of token type (RFC 7009 §2.1)
          revoked_sessions = sessions.to_a
          if revoked_sessions.any?
            now = Time.current
            session_ids = revoked_sessions.map(&:id)

            # Bulk-revoke in two queries (one UPDATE per table) instead of
            # issuing session.revoke! per row, which would be O(N) UPDATEs plus
            # another O(N) cascades to refresh_tokens.
            #
            # Tradeoff: update_all skips ActiveRecord callbacks, so the per-row
            # SESSION_REVOKED event emitted by Session#revoke! is not fired
            # automatically. We re-emit it explicitly below so audit-trail
            # subscribers (account status/locking, etc.) still see one event
            # per revoked session — the semantics are preserved, only the SQL
            # shape has changed.
            ActiveRecord::Base.transaction do
              StandardId::Session.where(id: session_ids).update_all(revoked_at: now)
              StandardId::RefreshToken
                .where(session_id: session_ids, revoked_at: nil)
                .update_all(revoked_at: now)
            end

            # DB state is already committed above; event publishing is best-effort
            # audit emission. A failing subscriber must not short-circuit the loop
            # and leave later sessions without their SESSION_REVOKED event, which
            # would permanently desync audit-trail consumers from the DB.
            revoked_sessions.each do |session|
              session.revoked_at = now
              begin
                StandardId::Events.publish(
                  StandardId::Events::SESSION_REVOKED,
                  session: session,
                  account: session.account,
                  reason: "token_revocation"
                )
              rescue StandardError => e
                StandardId.logger.error(
                  "[StandardId::Revocations] Failed to publish SESSION_REVOKED " \
                  "for session #{session.id}: #{e.class}: #{e.message}"
                )
              end
            end

            begin
              StandardId::Events.publish(
                StandardId::Events::OAUTH_TOKEN_REVOKED,
                account_id: account_id,
                sessions_revoked: revoked_sessions.size
              )
            rescue StandardError => e
              StandardId.logger.error(
                "[StandardId::Revocations] Failed to publish OAUTH_TOKEN_REVOKED " \
                "for account #{account_id}: #{e.class}: #{e.message}"
              )
            end
          end

          head :ok
        end
      end
    end
  end
end
