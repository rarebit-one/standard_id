module StandardId
  module Api
    class TokenManager
      attr_reader :request

      def initialize(request)
        @request = request
      end

      def create_device_session(account, device_id: nil, device_agent: nil)
        session_class = StandardId::SessionTypeResolver.resolve!(
          request: @request,
          account: account,
          flow: :api_device_auth
        )

        create_session_for(
          session_class,
          account: account,
          device_id: device_id,
          device_agent: device_agent
        )
      end

      def create_service_session(account, service_name:, service_version:, owner:, metadata: {})
        session_class = StandardId::SessionTypeResolver.resolve!(
          request: @request,
          account: account,
          flow: :api_service_auth
        )

        unless session_class == StandardId::ServiceSession
          raise StandardId::ConfigurationError,
            "session_type_resolver returned #{session_class.name} for flow :api_service_auth, " \
            "but service-session creation requires StandardId::ServiceSession " \
            "(service_name / service_version / owner are not applicable to other session types)."
        end

        StandardId::ServiceSession.create!(
          account: account,
          owner: owner,
          ip_address: StandardId::Utils::IpNormalizer.normalize(@request.remote_ip),
          service_name: service_name,
          service_version: service_version,
          metadata: metadata || {},
          expires_at: StandardId::ServiceSession.default_expiry
        )
      end

      def bearer_token
        return @bearer_token if defined?(@bearer_token)

        @bearer_token = StandardId::BearerTokenExtraction.extract(@request.headers["Authorization"])
      end

      # Verifies the bearer JWT and returns a decoded session.
      #
      # When `StandardId.config.oauth.allowed_audiences` is non-empty,
      # the token's `aud` claim is enforced against that list at decode
      # time. A mismatch raises `StandardId::InvalidAudienceError`, which
      # is caught and treated as an invalid token (returns nil) so the
      # downstream 401 path in `Api::BaseController` handles it
      # identically to signature/expiry failures.
      #
      # When the config is empty (default), no audience enforcement is
      # applied here — behavior is unchanged vs pre-threading releases.
      # Per-controller `AudienceVerification` concern still applies on
      # top for tighter endpoint-specific restrictions.
      def verify_jwt_token(token: bearer_token)
        StandardId::JwtService.decode_session(token, allowed_audiences: configured_allowed_audiences)
      rescue StandardId::InvalidAudienceError
        nil
      end

      def generate_lookup_hash(token)
        Digest::SHA256.hexdigest("#{token}:#{Rails.application.secret_key_base}")
      end

      private

      def create_session_for(session_class, account:, device_id: nil, device_agent: nil)
        base_attrs = {
          account: account,
          ip_address: StandardId::Utils::IpNormalizer.normalize(@request.remote_ip)
        }

        case session_class.name
        when "StandardId::DeviceSession"
          StandardId::DeviceSession.create!(
            **base_attrs,
            device_id: device_id || SecureRandom.uuid,
            device_agent: device_agent || @request.user_agent,
            expires_at: StandardId::DeviceSession.expiry
          )
        when "StandardId::BrowserSession"
          StandardId::BrowserSession.create!(
            **base_attrs,
            user_agent: device_agent || @request.user_agent,
            expires_at: StandardId::BrowserSession.expiry
          )
        else
          raise StandardId::ConfigurationError,
            "session_type_resolver returned #{session_class.name} for flow :api_device_auth; " \
            "expected :browser or :device."
        end
      end

      def configured_allowed_audiences
        audiences = StandardId.config.oauth.allowed_audiences
        audiences.presence
      end
    end
  end
end
