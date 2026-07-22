module StandardId
  module Api
    module Oauth
      class RevocationsController < BaseController
        VALID_REVOCATION_SCOPES = %i[account grant].freeze

        public_controller

        skip_before_action :validate_content_type!

        # POST /oauth/revoke
        # RFC 7009 - OAuth 2.0 Token Revocation
        #
        # Accepts a token and optional token_type_hint parameter.
        # Always responds with 200 OK regardless of whether the token
        # was valid or revocation was successful (per RFC 7009 Section 2.1).
        #
        # How much gets revoked is controlled by
        # `config.oauth.revocation_scope` (:account — historical, revoke every
        # active DeviceSession for the subject; :grant — revoke only the
        # authorization grant the presented token belongs to). See the schema
        # comment on that field.
        def create
          token = params[:token]
          head :ok and return if token.blank?

          payload = StandardId::JwtService.decode(token)
          head :ok and return unless payload&.dig(:sub)

          if revocation_scope == :grant
            revoke_presented_grant!(payload)
          else
            revoke_account_sessions!(payload[:sub])
          end

          head :ok
        end

        private

        def revocation_scope
          configured = StandardId.config.oauth.revocation_scope&.to_sym
          return configured if VALID_REVOCATION_SCOPES.include?(configured)

          StandardId.logger&.warn(
            "[StandardId::Revocations] Unknown config.oauth.revocation_scope " \
            "#{configured.inspect}; falling back to :account. Valid values: " \
            "#{VALID_REVOCATION_SCOPES.inspect}"
          )
          :account
        end

        # :account — the historical blast radius. Every active DeviceSession
        # for the subject is revoked, whichever token was presented.
        # ServiceSessions are deliberately excluded: they are machine
        # credentials with their own lifecycle, not something an interactive
        # client's logout should silently kill.
        def revoke_account_sessions!(account_id)
          sessions = StandardId::DeviceSession.where(account_id: account_id).active.to_a
          return if sessions.empty?

          refresh_tokens_revoked = revoke_sessions!(sessions)
          emit_token_revoked(
            account_id: account_id,
            sessions_revoked: sessions.size,
            refresh_tokens_revoked: refresh_tokens_revoked
          )
        end

        # :grant — RFC 7009 §2.1: revoke the presented token and the tokens
        # issued from the same authorization grant, nothing else.
        #
        # The lookup is by `jti`, which is type-agnostic: refresh tokens are
        # persisted as SHA256(jti) in standard_id_refresh_tokens, access tokens
        # are not persisted at all. That is why token_type_hint stays unused —
        # it is an optimisation hint for servers keeping separate per-type
        # stores (RFC 7009 §2.1), and a wrong hint must not change the outcome.
        # A presented access token therefore resolves to nothing and revokes
        # nothing: this engine cannot invalidate a stateless JWT before its
        # exp. Clients that need revocation to bite present the refresh token.
        def revoke_presented_grant!(payload)
          jti = payload[:jti]
          return if jti.blank?

          # Eager-load both associations: host apps run with
          # `strict_loading_by_default` (jumpdrive-web, luminality-web), where a
          # lazy `record.session` / `record.account` raises in their test env.
          record = StandardId::RefreshToken
            .where(token_digest: StandardId::RefreshToken.digest_for(jti))
            .includes(:session, :account)
            .first
          # A jti that resolves to another subject's grant must never revoke
          # it — the token was signature-verified, but bind the two identities
          # anyway rather than trusting a single claim.
          return if record.nil? || record.account_id.to_s != payload[:sub].to_s

          refresh_tokens_revoked = record.revoke_family!

          # The grant's Session, when the host app materialised one
          # (RefreshToken#session_id is nil unless the flow sets it).
          session = record.session
          sessions = (session && session.active?) ? [session] : []
          refresh_tokens_revoked += revoke_sessions!(sessions, account: record.account)

          emit_token_revoked(
            account_id: payload[:sub],
            sessions_revoked: sessions.size,
            refresh_tokens_revoked: refresh_tokens_revoked
          )
        end

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
        #
        # @return [Integer] number of refresh-token rows revoked by the cascade
        def revoke_sessions!(sessions, account: nil)
          return 0 if sessions.empty?

          now = Time.current
          session_ids = sessions.map(&:id)
          refresh_tokens_revoked = 0

          ActiveRecord::Base.transaction do
            StandardId::Session.where(id: session_ids).update_all(revoked_at: now)
            refresh_tokens_revoked = StandardId::RefreshToken
              .where(session_id: session_ids, revoked_at: nil)
              .update_all(revoked_at: now)
          end

          # DB state is already committed above; event publishing is best-effort
          # audit emission. A failing subscriber must not short-circuit the loop
          # and leave later sessions without their SESSION_REVOKED event, which
          # would permanently desync audit-trail consumers from the DB.
          #
          # All sessions here belong to the same account (both callers scope by
          # account), so we load the account once rather than calling
          # session.account per row, which would issue N extra SELECTs.
          shared_account = account || sessions.first.account
          sessions.each do |session|
            session.revoked_at = now
            begin
              StandardId::Events.publish(
                StandardId::Events::SESSION_REVOKED,
                session: session,
                account: shared_account,
                reason: "token_revocation"
              )
            rescue StandardError => e
              StandardId.logger.error(
                "[StandardId::Revocations] Failed to publish SESSION_REVOKED " \
                "for session #{session.id}: #{e.class}: #{e.message}"
              )
            end
          end

          refresh_tokens_revoked
        end

        def emit_token_revoked(account_id:, sessions_revoked:, refresh_tokens_revoked:)
          StandardId::Events.publish(
            StandardId::Events::OAUTH_TOKEN_REVOKED,
            account_id: account_id,
            sessions_revoked: sessions_revoked,
            refresh_tokens_revoked: refresh_tokens_revoked
          )
        rescue StandardError => e
          StandardId.logger.error(
            "[StandardId::Revocations] Failed to publish OAUTH_TOKEN_REVOKED " \
            "for account #{account_id}: #{e.class}: #{e.message}"
          )
        end
      end
    end
  end
end
