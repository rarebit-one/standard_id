module StandardId
  module Web
    class TokenManager
      attr_reader :request

      def initialize(request)
        @request = request
      end

      def create_browser_session(account)
        session_class = StandardId::SessionTypeResolver.resolve!(
          request: request,
          account: account,
          flow: :web_sign_in
        )

        create_session_for(session_class, account: account)
      end

      def create_remember_token(password_credential)
        {
          value: password_credential.generate_token_for(:remember_me),
          expires: StandardId::BrowserSession.remember_me_expiry,
          httponly: true,
          secure: request.ssl?,
          same_site: :lax
        }
      end

      private

      def create_session_for(session_class, account:)
        attrs = base_attributes(account: account).merge(
          session_specific_attributes(session_class)
        )
        session_class.create!(**attrs)
      end

      def base_attributes(account:)
        {
          account: account,
          ip_address: StandardId::Utils::IpNormalizer.normalize(request.remote_ip)
        }
      end

      def session_specific_attributes(session_class)
        case session_class.name
        when "StandardId::BrowserSession"
          {
            user_agent: request.user_agent,
            expires_at: StandardId::BrowserSession.expiry
          }
        when "StandardId::DeviceSession"
          {
            device_id: SecureRandom.uuid,
            device_agent: request.user_agent,
            expires_at: StandardId::DeviceSession.expiry
          }
        else
          raise StandardId::ConfigurationError,
            "session_type_resolver returned #{session_class.name} for flow :web_sign_in, " \
            "but web sign-in cannot infer the attributes required to create that session. " \
            "Return :browser or :device from this flow."
        end
      end
    end
  end
end
