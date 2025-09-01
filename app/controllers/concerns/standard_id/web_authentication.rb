module StandardId
  module WebAuthentication
    extend ActiveSupport::Concern

    included do
      helper_method :current_account, :authenticated?
    end

    private

    def authenticated?
      current_account.present?
    end

    def current_account
      Current.account ||= current_browser_session&.account
    end

    def current_browser_session
      session_manager.load_current_session
    end

    def require_browser_session!
      authentication_guard.require_session!(session_manager, session, request)
    end

    def after_authentication_url
      authentication_guard.after_authentication_url(session)
    end

    def sign_in_account(account)
      token_manager.sign_in_account(account, session_manager)
    end

    def sign_out_account
      current_browser_session&.revoke!
      session_manager.clear_session!
    end

    def create_remember_token(password_credential)
      token_manager.create_remember_token(password_credential, cookies)
    end

    def session_manager
      @session_manager ||= StandardId::Web::SessionManager.new(session, cookies, request, token_manager)
    end

    def token_manager
      @token_manager ||= StandardId::Web::TokenManager.new(request)
    end

    def authentication_guard
      @authentication_guard ||= StandardId::Web::AuthenticationGuard.new
    end
  end
end
