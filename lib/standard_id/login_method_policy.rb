module StandardId
  # Enforces `config.login_method_policy`: one decision point, consulted by
  # every engine flow that establishes a NEW authentication, after the
  # credential has been proven and before any session or token exists.
  #
  # ## Flows (the `flow:` the policy receives)
  #
  # | flow                            | auth_method    | where                                                    |
  # |---------------------------------|----------------|----------------------------------------------------------|
  # | :web_password                   | :password      | Web LoginController (WebAuthentication#sign_in_account)  |
  # | :web_signup                     | :password      | Web SignupController                                     |
  # | :web_passwordless               | :passwordless  | Web LoginVerifyController (email/SMS OTP)                |
  # | :web_social                     | :social        | Web Auth::Callback::ProvidersController                  |
  # | :web_remember_me                | :remember_me   | Web::SessionManager (remember-me cookie re-auth)         |
  # | :web_session                    | caller's, else :unspecified | Web::SessionManager#sign_in_account called by host code |
  # | :oauth_password_grant           | :password      | POST /oauth/token grant_type=password                    |
  # | :oauth_passwordless_otp_grant   | :passwordless  | POST /oauth/token grant_type=passwordless_otp            |
  # | :oauth_social_callback          | :social        | /oauth/callback/:provider (Oauth::SocialFlow)            |
  # | :oauth_refresh_token            | the ORIGINAL sign-in's, else :unspecified | POST /oauth/token grant_type=refresh_token |
  # | :api_device_session             | caller's, else :unspecified | Api::TokenManager#create_device_session (host code) |
  # | :api_service_session            | caller's, else :unspecified | Api::TokenManager#create_service_session (host code) |
  #
  # `refresh_token` is re-checked with the method of the authentication it
  # descends from (see StandardId::AuthLineage): a policy tightened after a
  # client signed in takes effect at that client's next refresh, and a refused
  # refresh revokes the token family (answered as `invalid_grant`). Tokens with
  # no recorded method (minted before 0.45) are checked as `:unspecified`.
  #
  # Not gated: `authorization_code` and the implicit flow (minted within
  # minutes from a browser session that passed the policy when it was created;
  # the code records that session's method for the refresh tokens it yields)
  # and `client_credentials` (no account). Live browser sessions that predate a
  # policy change are not re-checked; revoke them if they must end.
  #
  # ## Contract
  #
  # The policy is any object responding to `call`. It receives keywords and
  # may declare any subset of them (see Utils::CallableParameterFilter):
  # `account:`, `auth_method:`, `provider:`, `request:`, `flow:`.
  #
  # - truthy → allowed;
  # - `false` / `nil` → refused with LoginMethodDenied::DEFAULT_MESSAGE;
  # - `raise StandardId::LoginMethodDenied, "message"` → refused with that
  #   message.
  #
  # Any other exception propagates: a broken policy fails closed (the request
  # errors) rather than open.
  #
  # Every refusal publishes AUTHENTICATION_METHOD_DENIED before raising.
  module LoginMethodPolicy
    AUTH_METHODS = %i[password passwordless social remember_me unspecified].freeze

    FLOWS = %i[
      web_password web_signup web_passwordless web_social web_remember_me web_session
      oauth_password_grant oauth_passwordless_otp_grant oauth_social_callback oauth_refresh_token
      api_device_session api_service_session
    ].freeze

    module_function

    # Whether a policy is configured at all.
    def configured?
      !StandardId.config.login_method_policy.nil?
    end

    # @return [true] when allowed
    # @raise [StandardId::LoginMethodDenied] when refused
    # @raise [StandardId::ConfigurationError] when the policy is not callable
    def enforce!(account:, auth_method:, flow:, provider: nil, request: nil)
      policy = StandardId.config.login_method_policy
      return true if policy.nil?

      unless policy.respond_to?(:call)
        raise StandardId::ConfigurationError,
          "StandardId config: `login_method_policy` must respond to #call (got #{policy.class})"
      end

      auth_method = (auth_method || :unspecified).to_sym
      provider = provider&.to_s
      context = { account:, auth_method:, provider:, request:, flow: }

      message = nil
      allowed =
        begin
          policy.call(**StandardId::Utils::CallableParameterFilter.filter(policy, context))
        rescue StandardId::LoginMethodDenied => e
          message = e.message unless e.message == e.class.name
          false
        end
      return true if allowed

      denial = StandardId::LoginMethodDenied.new(message, auth_method:, provider:, flow:)
      publish_denied(account:, auth_method:, provider:, flow:, message: denial.message)
      raise denial
    end

    def publish_denied(account:, auth_method:, provider:, flow:, message:)
      StandardId::Events.publish(
        StandardId::Events::AUTHENTICATION_METHOD_DENIED,
        account: account,
        auth_method: auth_method.to_s,
        provider: provider,
        flow: flow.to_s,
        error_message: message
      )
    end
  end
end
