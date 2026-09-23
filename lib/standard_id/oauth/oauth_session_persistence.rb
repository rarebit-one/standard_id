module StandardId
  module Oauth
    # Persists a Session record when `config.session.session_type_resolver`
    # elects to materialise one for an OAuth token grant.
    #
    # Only supports BrowserSession / DeviceSession; ServiceSession requires
    # fields (service_name / service_version / owner) that the OAuth token
    # grant flow doesn't have context for.
    #
    # Uses a stable, deterministic device_id derived from account + user-agent
    # + audience so repeated token requests from the same device reuse the
    # session row instead of accumulating rows (mirrors the sidekick workaround
    # this config hook replaces).
    module OauthSessionPersistence
      module_function

      def persist!(session_class:, account:, request:, audience:, grant_type:)
        case session_class.name
        when "StandardId::DeviceSession"
          upsert_device_session!(
            account: account,
            request: request,
            audience: audience,
            grant_type: grant_type
          )
        when "StandardId::BrowserSession"
          StandardId::BrowserSession.create!(
            account: account,
            ip_address: StandardId::Utils::IpNormalizer.normalize(request.remote_ip),
            user_agent: request.user_agent.presence || "OAuth:#{grant_type}",
            expires_at: StandardId::BrowserSession.expiry
          )
        else
          raise StandardId::ConfigurationError,
            "session_type_resolver returned #{session_class.name} for flow :oauth_token_issued; " \
            "only :browser and :device are supported for OAuth-token-issued session creation."
        end
      end

      # Reuse the device's ACTIVE session row, or start a new one.
      #
      # Only a non-revoked row is eligible. Sign-out (/oauth/revoke under the
      # default :account revocation_scope) revokes every active DeviceSession
      # for the account; reusing that revoked row on the next sign-in — which a
      # bare `find_by(account:, device_id:)` did — linked every new refresh
      # token to a revoked parent, so RefreshTokenFlow#validate_parent_session!
      # refused the very first refresh and the client was bounced to sign-in
      # after every access-token expiry, forever. A revoked row is history (the
      # audit trail and admin session lists still read it); a new sign-in gets
      # a new row. Expiry is deliberately NOT part of eligibility: an expired
      # but unrevoked row is reused with its expires_at bumped, as before.
      def upsert_device_session!(account:, request:, audience:, grant_type:)
        user_agent = request.user_agent
        device_id = stable_device_id(account: account, user_agent: user_agent, audience: audience)
        ip_address = StandardId::Utils::IpNormalizer.normalize(request.remote_ip)

        # Serialize concurrent upserts for the same account. We acquire a
        # SELECT ... FOR UPDATE on the account row — account.with_lock is
        # unavailable because StandardId::AccountLocking overrides lock! with a
        # business-level method that takes a :reason kwarg. The outer
        # transaction (opened by TokenGrantFlow#generate_token_response)
        # releases the lock on commit/rollback.
        #
        # The lock alone is not the guarantee: the partial unique index from
        # 20260924000000 (one active row per account + device_id) is. The lock
        # keeps the common case free of unique violations; the savepoint below
        # handles the rest, and keeps hosts that have not yet run that
        # migration no worse off than before.
        account.class.where(id: account.id).lock.first

        existing = active_device_session(account: account, device_id: device_id)
        return refresh_device_session!(existing, ip_address: ip_address, user_agent: user_agent) if existing

        begin
          # Savepoint, so a unique violation does not abort the enclosing token
          # transaction (Postgres refuses every later statement in an aborted
          # transaction).
          StandardId::DeviceSession.transaction(requires_new: true) do
            StandardId::DeviceSession.create!(
              account: account,
              device_id: device_id,
              device_agent: user_agent.presence || "OAuth:#{grant_type}",
              ip_address: ip_address || "0.0.0.0",
              expires_at: StandardId::DeviceSession.expiry
            )
          end
        rescue ActiveRecord::RecordNotUnique
          # A concurrent sign-in for the same device committed its row first.
          # Reuse the winner rather than failing the token request.
          winner = active_device_session(account: account, device_id: device_id)
          raise unless winner

          refresh_device_session!(winner, ip_address: ip_address, user_agent: user_agent)
        end
      end

      # Newest first: before the unique index existed, a race could leave two
      # active rows for one device, and an unordered lookup picked one
      # arbitrarily. The migration detaches such duplicates, but hosts that
      # have not run it yet still benefit from a deterministic choice.
      def active_device_session(account:, device_id:)
        StandardId::DeviceSession
          .where(account: account, device_id: device_id, revoked_at: nil)
          .order(created_at: :desc, id: :desc)
          .first
      end

      def refresh_device_session!(session, ip_address:, user_agent:)
        session.update!(
          expires_at: StandardId::DeviceSession.expiry,
          ip_address: ip_address || session.ip_address,
          device_agent: user_agent || session.device_agent
        )
        session
      end

      def stable_device_id(account:, user_agent:, audience:)
        audience_key = Array(audience).join(",")
        Digest::SHA256.hexdigest("oauth:#{audience_key}:#{account.id}:#{user_agent}")[0, 36]
      end
    end
  end
end
