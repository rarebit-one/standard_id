module StandardId
  module WebAuthentication
    extend ActiveSupport::Concern

    included do
      include StandardId::InertiaSupport
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

    # Require authentication with redirect to login page instead of raising an error.
    # Use this for pages that should redirect unauthenticated users to login.
    def authenticate_account!
      return if authenticated?

      store_location_for_redirect
      redirect_to_login
    end

    # Store the current URL to redirect back after authentication
    def store_location_for_redirect
      session[:return_to_after_authenticating] = request.url if request.get?
    end

    # Redirect to login page, handling both Inertia and standard requests
    def redirect_to_login
      login_path = StandardId.config.login_url.presence || "/login"
      redirect_with_inertia login_path
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

        session_manager.sign_in_account(password_credential.account)
        session_manager.set_remember_cookie(password_credential) if remember_me
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
