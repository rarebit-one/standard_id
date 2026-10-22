module StandardId
  module EmailPassword
    # The sign-up code: issuing it (sign-up and resend) and confirming it.
    module Verification
      INVALID_CODE_MESSAGE = "Invalid or expired verification code."
      TOO_MANY_ATTEMPTS_MESSAGE = "Too many incorrect attempts. Please request a new code."
      LOCKED_OUT_MESSAGE = "Too many incorrect attempts. Please try again tomorrow."

      class << self
        # Confirms the code for a pending sign-up, verifies the address and runs
        # `c.email_password.after_email_verified` when the sign-up was made
        # through Registration (EmailPassword.api_signup?), as a reset does: an
        # unverified web sign-up that verifies here is verified without it.
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
        # Given a block, yields the account with the password credential's row
        # locked, after re-checking that the password has not changed since it
        # was checked, as Authentication.call does: mint tokens inside it, so a
        # password reset racing this verification either finishes first (and
        # this answers :invalid_code) or revokes what it minted.
        #
        # @return [Account] ready for EmailPassword::TokenFlow
        # @raise [StandardId::EmailPasswordError] :invalid_code
        def verify!(email:, code:, password:, request: nil)
          email = EmailPassword.normalize_email(email)
          password_credential = EmailPassword.credential_for_password(email, password)
          identifier = password_credential&.credential&.identifier
          raise invalid_code(INVALID_CODE_MESSAGE) if identifier.nil?
          raise invalid_code(LOCKED_OUT_MESSAGE) if DailyLimit.exceeded?(:failed_verification, email)

          verified_digest = password_credential.password_digest

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
          account = ActiveRecord::Base.transaction do
            password_unchanged!(password_credential, verified_digest)
            EmailPassword.complete_verification!(
              identifier,
              name: otp.challenge&.metadata&.dig("name"),
              request: request,
              run_hook: EmailPassword.api_signup?(identifier)
            )
            identifier.account
          end
          return account unless block_given?

          password_credential.with_lock do
            password_unchanged!(password_credential, verified_digest)
            yield account
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
            metadata: { "name" => name.presence || EmailPassword.signup_name(email) }.compact
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

        # Locks the credential (in the caller's transaction) and refuses the
        # verification if a reset changed the password after it was checked.
        def password_unchanged!(password_credential, verified_digest)
          password_credential.lock!
          raise invalid_code(INVALID_CODE_MESSAGE) unless password_credential.password_digest == verified_digest
        end

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
      end
    end
  end
end
