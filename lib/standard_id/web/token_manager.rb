module StandardId
  module Web
    class TokenManager
      def initialize(request)
        @request = request
      end

      def create_browser_session(account, remember_me: false)
        StandardId::BrowserSession.create!(
          account: account,
          ip_address: @request.remote_ip,
          user_agent: @request.user_agent,
          expires_at: remember_me ? 30.days.from_now : 24.hours.from_now # TODO: make these configurable
        )
      end

      def create_remember_token(password_credential, cookies)
        cookies[:remember_token] = {
          value: password_credential.generate_token_for(:remember_me),
          expires: password_credential.expires_at,
          httponly: true,
          secure: @request.ssl?,
          same_site: :lax
        }
      end

      def sign_in_account(account, session_manager)
        browser_session = create_browser_session(account)
        session_manager.set_session_token(browser_session.instance_variable_get(:@token))
        Current.session = browser_session
        browser_session
      end
    end
  end
end
