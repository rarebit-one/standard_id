module StandardId
  module ApiAuthentication
    extend ActiveSupport::Concern

    included do
      if StandardId.config.alias_current_user
        define_method(:current_user) { current_account }
      end

      # Only require_recent_authentication! raises it, so a controller that
      # never calls the guard never reaches this.
      rescue_from StandardId::StepUpRequiredError, with: :render_step_up_required
    end

    delegate :current_session, :current_account, :revoke_current_session!, to: :session_manager

    private

    def authenticated?
      current_account.present?
    end

    def verify_access_token!
      authentication_guard.require_session!(session_manager)
    end

    def require_scopes!(*required_scopes)
      authentication_guard.require_scopes!(session_manager, *required_scopes)
    end

    # Step-up guard for a sensitive action (opt-in, see StandardId::StepUp):
    # verifies the access token, then requires its `auth_time` claim to be
    # within +within+ (default c.step_up.max_age). A stale or missing
    # `auth_time` raises StandardId::StepUpRequiredError, rendered as RFC 9470's
    # challenge (#render_step_up_required); the client steps up through
    # POST /step_up and /step_up/verify and retries with the token that returns.
    # Needs c.step_up.enabled; raises StandardId::ConfigurationError otherwise.
    def require_recent_authentication!(within: StandardId::StepUp.max_age)
      StandardId::StepUp.ensure_usable!
      api_session = verify_access_token!
      return api_session if StandardId::StepUp.recent?(api_session, within: within)

      raise StandardId::StepUpRequiredError.new(max_age: within)
    end

    # RFC 9470 §3: 401 with `error="insufficient_user_authentication"` and the
    # `max_age` the authentication may have. Override to answer differently.
    def render_step_up_required(error)
      description = error.message
      challenge = %(Bearer realm="StandardId", error="insufficient_user_authentication", error_description="#{description}")
      challenge += %(, max_age=#{error.max_age}) if error.max_age
      response.set_header("WWW-Authenticate", challenge)
      render json: { error: "insufficient_user_authentication", error_description: description, max_age: error.max_age }.compact,
        status: :unauthorized
    end

    def session_manager
      @session_manager ||= StandardId::Api::SessionManager.new(token_manager, request:)
    end

    def token_manager
      @token_manager ||= StandardId::Api::TokenManager.new(request)
    end

    def authentication_guard
      @authentication_guard ||= StandardId::Api::AuthenticationGuard.new
    end
  end
end
