module StandardId
  # Public concern for host app controllers that need passwordless OTP capabilities.
  #
  # Include this in your custom controllers to generate and verify OTP codes
  # without mounting the WebEngine's built-in login controllers.
  #
  # Requires the including controller to have access to `request` (standard in
  # all Rails controllers). No other dependencies are needed -- both
  # `generate_passwordless_otp` and `verify_passwordless_otp` only use `request`;
  # `start_passwordless_login` also writes to `session`.
  #
  # @example Usage in a host app controller
  #   class Auth::LoginController < ApplicationController
  #     include StandardId::PasswordlessFlow
  #     include StandardId::WebAuthentication # needed for session_manager
  #     include StandardId::LifecycleHooks
  #
  #     def create
  #       generate_passwordless_otp(username: params[:email])
  #       redirect_to verify_path
  #     end
  #
  #     def verify
  #       result = verify_passwordless_otp(username: params[:email], code: params[:code])
  #       if result.success?
  #         session_manager.sign_in_account(result.account)
  #         redirect_to root_path
  #       else
  #         render :verify, status: :unprocessable_content
  #       end
  #     end
  #   end
  #
  # @example Hand off to the WebEngine's verify page (no custom verify action)
  #   class Onboarding::SignupsController < ApplicationController
  #     include StandardId::PasswordlessFlow
  #
  #     def create
  #       start_passwordless_login(username: params[:email], return_to: welcome_path)
  #       redirect_to standard_id_web.login_verify_path, status: :see_other
  #     rescue StandardId::InvalidRequestError => e
  #       redirect_to new_signup_path, alert: e.message
  #     end
  #   end
  module PasswordlessFlow
    extend ActiveSupport::Concern

    include StandardId::PasswordlessStrategy

    # Session key for the signed hand-off the WebEngine's login_verify page reads.
    OTP_PAYLOAD_SESSION_KEY = :standard_id_otp_payload

    private

    # Start a passwordless login that the WebEngine's login_verify page finishes.
    #
    # Sends the code (as `generate_passwordless_otp`), then stores the signed
    # hand-off that login_verify requires, valid for `passwordless.code_ttl`.
    # The caller redirects to that page itself, through the engine's mounted
    # helper so the mount path is included (e.g. `standard_id_web.login_verify_path`).
    #
    # Nothing is stored when sending fails, so the verify page is never reachable
    # for a code that was not sent.
    #
    # @param username [String] the recipient's email address or phone number
    # @param connection [String] the delivery channel, defaults to `passwordless.connection`
    # @param return_to [String, nil] where to send the account after it verifies;
    #   the verify page still checks it is a safe destination. Non-String values are ignored.
    # @return [StandardId::CodeChallenge] the created code challenge
    # @raise [StandardId::InvalidRequestError] when the username format is invalid
    #   or the connection type is unsupported
    def start_passwordless_login(username:, connection: StandardId.config.passwordless.connection, return_to: nil)
      challenge = generate_passwordless_otp(username: username, connection: connection)
      store_passwordless_handoff(username: username, connection: connection)
      session[:return_to_after_authenticating] = return_to if return_to.is_a?(String) && return_to.present?
      challenge
    end

    def store_passwordless_handoff(username:, connection:)
      session[OTP_PAYLOAD_SESSION_KEY] = Rails.application.message_verifier(:otp).generate(
        { username: username, connection: connection },
        expires_in: StandardId.config.passwordless.code_ttl.seconds
      )
    end

    # The stored hand-off as `{ username:, connection: }`, or nil when there is
    # none. A tampered or expired hand-off is deleted and raises
    # ActiveSupport::MessageVerifier::InvalidSignature.
    def read_passwordless_handoff
      signed_payload = session[OTP_PAYLOAD_SESSION_KEY]
      return if signed_payload.blank?

      Rails.application.message_verifier(:otp).verify(signed_payload).symbolize_keys
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      clear_passwordless_handoff
      raise
    end

    def clear_passwordless_handoff
      session.delete(OTP_PAYLOAD_SESSION_KEY)
    end

    # Generate a passwordless OTP code and send it to the user.
    #
    # Delegates to the appropriate strategy (EmailStrategy or SmsStrategy)
    # based on the connection type. The strategy validates the username,
    # creates a CodeChallenge, and triggers the configured sender callback.
    #
    # @param username [String] the recipient's email address or phone number
    # @param connection [String] the delivery channel ("email" or "sms"), defaults to "email"
    # @return [StandardId::CodeChallenge] the created code challenge
    # @raise [StandardId::InvalidRequestError] when the username format is invalid
    #   or the connection type is unsupported
    def generate_passwordless_otp(username:, connection: "email")
      strategy = strategy_for(connection)
      strategy.start!(username: username, connection: connection)
    end

    # Verify a passwordless OTP code and resolve the account.
    #
    # Delegates to `StandardId::Passwordless.verify`, which handles code
    # validation, constant-time comparison, attempt tracking, and account
    # resolution (find or create).
    #
    # @param username [String] the identifier value (email or phone number)
    # @param code [String] the OTP code to verify
    # @param connection [String] the delivery channel ("email" or "sms"), defaults to "email"
    # @param allow_registration [Boolean] whether to create a new account if none exists (default: true).
    #   When the including controller resolves a scope (StandardId::LifecycleHooks#current_scope_config)
    #   and that scope sets `allow_registration: false`, registration is refused regardless —
    #   a scope can only restrict.
    # @return [StandardId::Passwordless::VerificationService::Result] a result with:
    #   - success? -- true when verification succeeded
    #   - account  -- the authenticated/created account (nil on failure)
    #   - challenge -- the consumed CodeChallenge (nil on failure)
    #   - error -- human-readable message (nil on success)
    #   - error_code -- machine-readable symbol (nil on success):
    #       :invalid_code, :expired, :max_attempts, :not_found, :blank_code,
    #       :account_not_found, :server_error
    #   - attempts -- failed attempt count (nil on success)
    def verify_passwordless_otp(username:, code:, connection: "email", allow_registration: true)
      StandardId::Passwordless.verify(
        username: username,
        code: code,
        connection: connection,
        request: request,
        allow_registration: StandardId::ScopeConfig.registration_allowed?(allow_registration, passwordless_scope_config)
      )
    end

    # The active ScopeConfig when the controller also includes
    # StandardId::LifecycleHooks; nil otherwise (no scope → no restriction).
    def passwordless_scope_config
      respond_to?(:current_scope_config, true) ? current_scope_config : nil
    end
  end
end
