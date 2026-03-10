module StandardId
  module WebAuthentication
    extend ActiveSupport::Concern

    included do
      include StandardId::InertiaSupport
      helper_method :current_account, :authenticated?

      if StandardId.config.alias_current_user
        define_method(:current_user) { current_account }
        helper_method :current_user
      end
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

      # Add redirect_uri parameter to preserve the original destination
      if request.get?
        uri = URI.parse(login_path)
        params = Rack::Utils.parse_nested_query(uri.query)
        params["redirect_uri"] = request.fullpath
        uri.query = params.to_query.presence
        login_path = uri.to_s
      end

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

      StandardId::Events.publish(
        StandardId::Events::AUTHENTICATION_ATTEMPT_STARTED,
        account_lookup: login,
        auth_method: "password"
      )

      StandardId::PasswordCredential.find_by(login:).tap do |password_credential|
        authenticated = password_credential&.authenticate(password)

        # Perform a dummy bcrypt comparison when the credential doesn't exist
        # to prevent user enumeration via response timing differences.
        BCrypt::Password.new(dummy_password_digest).is_password?(password) unless password_credential

        unless authenticated
          StandardId::Events.publish(
            StandardId::Events::AUTHENTICATION_FAILED,
            account_lookup: login,
            auth_method: "password",
            error_code: "invalid_credentials",
            error_message: "Invalid login or password"
          )
          return nil
        end

        StandardId::Events.publish(
          StandardId::Events::PASSWORD_VALIDATED,
          account: password_credential.account,
          credential_id: password_credential.id
        )

        session_manager.sign_in_account(password_credential.account)
        session_manager.set_remember_cookie(password_credential) if remember_me

        StandardId::Events.publish(
          StandardId::Events::AUTHENTICATION_SUCCEEDED,
          account: password_credential.account,
          auth_method: "password",
          session_type: "browser"
        )
      end
    end

    def session_manager
      @session_manager ||= StandardId::Web::SessionManager.new(token_manager, request: request, session: session, cookies: cookies)
    end

    def token_manager
      @token_manager ||= StandardId::Web::TokenManager.new(request)
    end

    def dummy_password_digest
      @dummy_password_digest ||= BCrypt::Password.create("").freeze
    end

    def authentication_guard
      @authentication_guard ||= StandardId::Web::AuthenticationGuard.new
    end
  end
end
