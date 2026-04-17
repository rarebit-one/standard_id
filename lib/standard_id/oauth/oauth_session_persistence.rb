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

      def upsert_device_session!(account:, request:, audience:, grant_type:)
        user_agent = request.user_agent
        device_id = stable_device_id(account: account, user_agent: user_agent, audience: audience)
        ip_address = StandardId::Utils::IpNormalizer.normalize(request.remote_ip)

        existing = StandardId::DeviceSession.find_by(account: account, device_id: device_id)
        if existing
          existing.update!(
            expires_at: StandardId::DeviceSession.expiry,
            ip_address: ip_address || existing.ip_address,
            device_agent: user_agent || existing.device_agent
          )
          existing
        else
          StandardId::DeviceSession.create!(
            account: account,
            device_id: device_id,
            device_agent: user_agent.presence || "OAuth:#{grant_type}",
            ip_address: ip_address || "0.0.0.0",
            expires_at: StandardId::DeviceSession.expiry
          )
        end
      end

      def stable_device_id(account:, user_agent:, audience:)
        audience_key = Array(audience).join(",")
        Digest::SHA256.hexdigest("oauth:#{audience_key}:#{account.id}:#{user_agent}")[0, 36]
      end
    end
  end
end
