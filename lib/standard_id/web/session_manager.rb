module StandardId
  module Web
    class SessionManager
      attr_reader :token_manager, :request, :session, :cookies

      def initialize(token_manager, request:, session:, cookies:)
        @token_manager = token_manager
        @request = request
        @session = session
        @cookies = cookies
      end

      def current_session
        Current.session ||= load_current_session
      end

      def current_account
        Current.account ||= current_session&.account
      end

      def sign_in_account(account, remember_me: false)
        token_manager.create_browser_session(account).tap do |browser_session|
          session[:session_token] = browser_session.token
          Current.session = browser_session
        end
      end

      def revoke_current_session!
        current_session&.revoke!
        clear_session!
      end

      def clear_session!
        # TODO: make token key names configurable
        session.delete(:session_token)
        cookies.delete(:remember_token)

        Current.session = nil
      end

      private

      def load_current_session
        Current.session ||= load_session_from_session_token
        Current.session ||= load_session_from_remember_token

        clear_session! if Current.session.blank? || Current.session.expired? || Current.session.revoked?

        Current.session
      end

      def load_session_from_session_token
        StandardId::BrowserSession.eager_load(:account).by_token(session[:session_token]).first
      end

      def load_session_from_remember_token
        password_credential = StandardId::PasswordCredential.find_by_token_for(:remember_me, cookies[:remember_token])
        return if password_credential.blank?

        token_manager.create_browser_session(password_credential.account, remember_me: true).tap do |browser_session|
          session[:session_token] = browser_session.token
          cookies[:remember_token] = token_manager.create_remember_token(password_credential)
        end
      end
    end
  end
end
