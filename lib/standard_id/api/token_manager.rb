module StandardId
  module Api
    class TokenManager
      def initialize(request)
        @request = request
      end

      def extract_bearer_token
        auth_header = @request.headers["Authorization"]
        return unless auth_header&.start_with?("Bearer ")

        auth_header.split(" ", 2).last
      end

      def generate_lookup_hash(token)
        Digest::SHA256.hexdigest("#{token}:#{Rails.application.secret_key_base}")
      end

      def create_device_session(account, device_id: nil, device_agent: nil)
        StandardId::DeviceSession.create!(
          account:,
          ip_address: @request.remote_ip,
          device_id: device_id || SecureRandom.uuid,
          device_agent: device_agent || @request.user_agent,
          expires_at: 30.days.from_now # TODO: make this configurable
        )
      end

      def create_service_session(account, service_name:, service_version:, owner: nil, metadata: {})
        StandardId::ServiceSession.create!(
          account:,
          owner:,
          ip_address: @request.remote_ip,
          service_name:,
          service_version:,
          metadata:,
          expires_at: StandardId::ServiceSession.default_expiry
        )
      end
    end
  end
end
