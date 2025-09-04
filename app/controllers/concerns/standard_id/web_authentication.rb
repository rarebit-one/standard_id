module StandardId
  module WebAuthentication
    extend ActiveSupport::Concern

    included do
      helper_method :current_account, :authenticated?
    end

    delegate :current_session, :current_account, :revoke_current_session!, to: :session_manager

    private

    def authenticated?
      current_account.present?
    end

    def require_browser_session!
      authentication_guard.require_session!(session_manager, session: session, request: request)
    end

    def after_authentication_url
      # TODO: add configurable value
      session.delete(:return_to_after_authenticating) || "/"
    end

    def sign_in_account(login_params)
      login = login_params[:email] || login_params[:login] # support both :email and :login keys
      password = login_params[:password]
      remember_me = ActiveModel::Type::Boolean.new.cast(login_params[:remember_me])

      StandardId::PasswordCredential.find_by(login:).tap do |password_credential|
        return nil unless password_credential&.authenticate(password)

        session_manager.sign_in_account(password_credential.account, remember_me:)
        cookies[:remember_token] = token_manager.create_remember_token(password_credential) if remember_me
      end
    end

    def session_manager
      @session_manager ||= StandardId::Web::SessionManager.new(token_manager, request: request, session: session, cookies: cookies)
    end

    def token_manager
      @token_manager ||= StandardId::Web::TokenManager.new(request)
    end

    def authentication_guard
      @authentication_guard ||= StandardId::Web::AuthenticationGuard.new
    end
  end
end
