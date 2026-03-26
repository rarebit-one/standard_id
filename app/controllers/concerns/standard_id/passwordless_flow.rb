module StandardId
  # Public concern for host app controllers that need passwordless OTP capabilities.
  #
  # Include this in your custom controllers to generate and verify OTP codes
  # without mounting the WebEngine's built-in login controllers.
  #
  # Requires the including controller to have access to `request` (standard in
  # all Rails controllers). No other dependencies are needed -- both
  # `generate_passwordless_otp` and `verify_passwordless_otp` only use `request`.
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
  module PasswordlessFlow
    extend ActiveSupport::Concern

    include StandardId::PasswordlessStrategy

    private

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
    # @param allow_registration [Boolean] whether to create a new account if none exists (default: true)
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
        allow_registration: allow_registration
      )
    end
  end
end
