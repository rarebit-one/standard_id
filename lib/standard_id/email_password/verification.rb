module StandardId
  module EmailPassword
    # The sign-up code: issuing it (sign-up and resend) and confirming it.
    module Verification
      INVALID_CODE_MESSAGE = "Invalid or expired verification code."
      TOO_MANY_ATTEMPTS_MESSAGE = "Too many incorrect attempts. Please request a new code."
      LOCKED_OUT_MESSAGE = "Too many incorrect attempts. Please try again tomorrow."

      class << self
        # Confirms the code for a pending sign-up, verifies the address and runs
        # `c.email_password.after_email_verified`.
        #
        # Requires the sign-up password as well as the code. Code alone would be
        # a takeover: anyone could start a sign-up for an address and the
        # owner's code would then confirm an account the stranger controls. The
        # password is checked FIRST and a mismatch is answered exactly like a
        # wrong code, so a guessed code is never even compared without it.
        #
        # A wrong code sent WITH the right password counts toward
        # rate_limits.email_password_failed_verifications_per_day; at the cap the
        # address cannot verify, even with the right code, until the window
        # passes. A wrong password does not count, so a stranger cannot burn the
        # registrant's daily allowance, and only the right password is told the
        # address is locked out (otherwise the lockout would reveal that the
        # address has a pending sign-up). The controller's short per-email
        # limit (rate_limits.email_password_verify_per_email) does count every
        # request, so a stranger CAN hold verification off for that window.
        #
        # @return [Account] ready for EmailPassword::TokenFlow
        # @raise [StandardId::EmailPasswordError] :invalid_code
        def verify!(email:, code:, password:, request: nil)
          email = EmailPassword.normalize_email(email)
          identifier = EmailPassword.identifier_for_password(email, password)
          raise invalid_code(INVALID_CODE_MESSAGE) if identifier.nil?
          raise invalid_code(LOCKED_OUT_MESSAGE) if DailyLimit.exceeded?(:failed_verification, email)

          otp = StandardId::Otp.verify(
            realm: EmailPassword.config.verification_realm,
            target: email,
            channel: :email,
            code: code.to_s.strip,
            request: request
          )
          failed!(email, otp.error_code) unless otp.success?

          # The hook runs in the same transaction as the verification: if it
          # raises, the address stays unverified, so the registrant can ask for
          # a new code (this one is spent) and the hook runs again. Otherwise a
          # failed hook would leave a verified account that login lets in
          # without ever provisioning it.
          ActiveRecord::Base.transaction do
            identifier.verify! unless identifier.verified?
            account = identifier.account

            hook = EmailPassword.config.after_email_verified
            if hook.respond_to?(:call)
              EmailPassword.call_hook(hook, account: account, name: otp.challenge&.metadata&.dig("name"), request: request)
            end

            account
          end
        end

        # Resend: issues a fresh code for a pending sign-up, only when +password+
        # is its password. Otherwise a silent no-op: the endpoint answers the
        # same either way, so it cannot probe which addresses have accounts, and
        # a stranger cannot spend the registrant's daily code allowance.
        #
        # @return [Boolean] whether a code was issued
        def send_code(email:, password:, name: nil, request: nil)
          email = EmailPassword.normalize_email(email)
          return false unless EmailPassword.pending_identifier(email, password)

          issue_code(email, name: name, request: request)
        end

        # Issues and delivers a code for +email+ without checking for a pending
        # sign-up (Registration has just done so). At most
        # rate_limits.email_password_codes_per_day per address; past that, and
        # while passwordless.retry_delay is still running (the code already
        # sent stays valid), a silent no-op.
        #
        # The name given at sign-up rides on the challenge's metadata until the
        # code is confirmed; a resend carries it forward.
        #
        # @return [Boolean] whether a code was issued
        def issue_code(email, name: nil, request: nil)
          return false if DailyLimit.exceeded?(:code_issued, email)

          config = EmailPassword.config
          built_in = config.code_delivery.to_sym == :built_in
          result = StandardId::Otp.issue(
            realm: config.verification_realm,
            target: email,
            channel: :email,
            request: request,
            delivery: built_in ? :manual : :custom,
            metadata: { "name" => name.presence || pending_name(email) }.compact
          )
          return false unless result.success?

          DailyLimit.record!(:code_issued, email)
          if built_in
            StandardId::PasswordlessMailer
              .with(email: email, otp_code: result.code, realm: config.verification_realm)
              .verification_email
              .deliver_later
          end
          true
        end

        private

        def failed!(email, error_code)
          count = DailyLimit.record!(:failed_verification, email)
          message = if count >= DailyLimit.limit(:failed_verification)
            LOCKED_OUT_MESSAGE
          elsif error_code == :max_attempts
            TOO_MANY_ATTEMPTS_MESSAGE
          else
            INVALID_CODE_MESSAGE
          end
          raise invalid_code(message)
        end

        def invalid_code(message)
          StandardId::EmailPasswordError.new(:invalid_code, message)
        end

        def pending_name(email)
          StandardId::CodeChallenge
            .where(realm: EmailPassword.config.verification_realm, channel: "email", target: email)
            .order(created_at: :desc)
            .pick(:metadata)
            &.dig("name")
        end
      end
    end
  end
end
