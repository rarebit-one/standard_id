require "standard_id/passwordless/verification_service"

module StandardId
  module Passwordless
    class << self
      # Public API for verifying a passwordless OTP code.
      #
      # This is the recommended entry point for host apps that need OTP
      # verification without mounting WebEngine. It wraps
      # VerificationService.verify with the same interface and result type.
      #
      # @param username [String] The identifier value (email or phone number)
      # @param code [String] The OTP code to verify
      # @param connection [String] Channel type ("email" or "sms")
      # @param request [ActionDispatch::Request] The current request
      # @return [VerificationService::Result] A result with:
      #   - success? — true when verification succeeded
      #   - account  — the authenticated/created account (nil on failure)
      #   - challenge — the consumed CodeChallenge (nil on failure)
      #   - error — human-readable message (nil on success)
      #   - error_code — machine-readable symbol (nil on success):
      #       :invalid_code, :max_attempts, :not_found, :blank_code,
      #       :account_not_found, :server_error
      #   - attempts — failed attempt count (nil on success)
      #
      # @example
      #   result = StandardId::Passwordless.verify(
      #     username: "user@example.com",
      #     code: "123456",
      #     connection: "email",
      #     request: request
      #   )
      #
      #   if result.success?
      #     sign_in(result.account)
      #   else
      #     case result.error_code
      #     when :invalid_code then render_invalid_code
      #     when :max_attempts then render_locked_out
      #     when :not_found    then render_not_found
      #     end
      #   end
      #
      def verify(username:, code:, connection:, request:, allow_registration: true)
        VerificationService.verify(
          connection: connection,
          username: username,
          code: code,
          request: request,
          allow_registration: allow_registration
        )
      end

      # Resolve the configured OTP code length, clamped to a sane range.
      # Shared by all OTP generators in the engine so one setting controls the
      # code space end-to-end.
      def otp_code_length
        configured = StandardId.config.passwordless.code_length
        length = configured.to_i
        length = 6 if length <= 0
        length.clamp(4, 10)
      end

      # Generate a zero-padded numeric OTP code at the configured length.
      # Single source of truth — used by BaseStrategy and by the verify_email
      # / verify_phone start controllers so a change to the generation formula
      # only needs to happen here.
      #
      # Codes may begin with leading zeros (e.g. "000123"). Host apps that
      # display or round-trip codes should treat them as strings.
      def generate_otp_code
        length = otp_code_length
        SecureRandom.random_number(10**length).to_s.rjust(length, "0")
      end

      # Resolve the per-challenge attempt ceiling, preferring the newer
      # :max_attempts_per_challenge setting but falling back to :max_attempts
      # for backwards compatibility with apps that configured the older name.
      def max_attempts_per_challenge
        configured = StandardId.config.passwordless.max_attempts_per_challenge
        return configured.to_i if configured && configured.to_i.positive?

        legacy = StandardId.config.passwordless.max_attempts.to_i
        legacy.positive? ? legacy : 5
      end
    end
  end
end
