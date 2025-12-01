module StandardId
  module Web
    class TokenManager
      attr_reader :request

      def initialize(request)
        @request = request
      end

      def create_browser_session(account)
        StandardId::BrowserSession.create!(
          account: account,
          ip_address: request.remote_ip,
          user_agent: request.user_agent,
          expires_at: StandardId::BrowserSession.expiry
        )
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
    end
  end
end
