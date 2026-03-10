module StandardId
  module Api
    class TokenManager
      attr_reader :request

      def initialize(request)
        @request = request
      end

      def create_device_session(account, device_id: nil, device_agent: nil)
        StandardId::DeviceSession.create!(
          account:,
          ip_address: @request.remote_ip,
          device_id: device_id || SecureRandom.uuid,
          device_agent: device_agent || @request.user_agent,
          expires_at: StandardId::DeviceSession.expiry
        )
      end

      def create_service_session(account, service_name:, service_version:, owner:, metadata: {})
        StandardId::ServiceSession.create!(
          account:,
          owner:,
          ip_address: @request.remote_ip,
          service_name:,
          service_version:,
          metadata: metadata || {},
          expires_at: StandardId::ServiceSession.default_expiry
        )
      end

      def bearer_token
        return @bearer_token if defined?(@bearer_token)

        @bearer_token = StandardId::BearerTokenExtraction.extract(@request.headers["Authorization"])
      end

      def verify_jwt_token(token: bearer_token)
        StandardId::JwtService.decode_session(token)
      end

      def generate_lookup_hash(token)
        Digest::SHA256.hexdigest("#{token}:#{Rails.application.secret_key_base}")
      end
    end
  end
end
