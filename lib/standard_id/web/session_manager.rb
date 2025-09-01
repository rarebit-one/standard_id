module StandardId
  module Web
    class SessionManager
      def initialize(session, cookies, request, token_manager)
        @session = session
        @cookies = cookies
        @request = request
        @token_manager = token_manager
      end

      def load_current_session
        return Current.session if Current.session.present?

        Current.session ||= load_session_from_session_token
        Current.session ||= load_session_from_remember_token

        clear_session! if Current.session.blank? || Current.session.expired? || Current.session.revoked?

        Current.session
      end

      def clear_session!
        # TODO: make token key names configurable
        @session.delete(:session_token)
        @cookies.delete(:remember_token)

        Current.session = nil
      end

      def set_session_token(token)
        @session[:session_token] = token
      end

      def session_token
        @session[:session_token]
      end

      private


      def load_session_from_session_token
        return unless session_token
        StandardId::BrowserSession.eager_load(:account).by_token(session_token).first
      end

      def load_session_from_remember_token
        password_credential = StandardId::PasswordCredential.find_by_token_for(:remember_me, @cookies[:remember_token])
        return if password_credential.blank?

        browser_session = @token_manager.create_browser_session(password_credential.account, remember_me: true)
        set_session_token(browser_session.instance_variable_get(:@token))
        @token_manager.create_remember_token(password_credential, @cookies)

        browser_session
      end
    end
  end
end
