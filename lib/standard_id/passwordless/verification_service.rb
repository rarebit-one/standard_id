module StandardId
  module Passwordless
    # Shared canonical realm used by the authentication flow. Kept in one
    # place so BaseStrategy, VerificationService, and Otp can't drift.
    DEFAULT_REALM = "authentication".freeze

    class VerificationService
      # Result object returned by .verify.
      # - success?: true/false
      # - account: the resolved account (nil on failure)
      # - challenge: the consumed CodeChallenge (nil on failure)
      # - error: human-readable error message string (nil on success)
      # - error_code: machine-readable symbol (nil on success)
      #   One of :invalid_code, :expired, :max_attempts, :not_found, :blank_code,
      #   :account_not_found, :server_error
      # - attempts: nil on success, 0 when no challenge was found (fabricated
      #   target), or 1+ for wrong-code failures against an active challenge
      Result = Data.define(:success?, :account, :challenge, :error, :error_code, :attempts)

      STRATEGY_MAP = {
        "email" => StandardId::Passwordless::EmailStrategy,
        "sms"   => StandardId::Passwordless::SmsStrategy
      }.freeze

      class << self
        # Verify a passwordless OTP code and resolve the account.
        #
        # @param email [String, nil] The email address (mutually exclusive with phone)
        # @param phone [String, nil] The phone number (mutually exclusive with email)
        # @param connection [String, nil] Channel type ("email" or "sms") — convenience
        #   alternative to email:/phone: (use with username:)
        # @param username [String, nil] The identifier value — used with connection:
        # @param code [String] The OTP code to verify
        # @param request [ActionDispatch::Request] The current request (needed for strategy)
        # @return [Result] A result object with success?, account, challenge, error, and attempts
        #
        # OTP_VALIDATION_FAILED / PASSWORDLESS_CODE_FAILED events are only emitted
        # when an active challenge exists but the code is wrong. Requests with no
        # matching challenge (e.g. fabricated usernames) do not emit failure events
        # — this avoids noise from speculative probes that never triggered a code.
        # NOTE: This is a behavioral change from the pre-extraction API flow
        # (PasswordlessOtpFlow), which emitted failure events unconditionally.
        #
        # @example Using connection/username (preferred for callers with channel info)
        #   result = StandardId::Passwordless::VerificationService.verify(
        #     connection: "email",
        #     username: "user@example.com",
        #     code: "123456",
        #     request: request
        #   )
        #
        # @example Using email/phone directly
        #   result = StandardId::Passwordless::VerificationService.verify(
        #     email: "user@example.com",
        #     code: "123456",
        #     request: request
        #   )
        #   if result.success?
        #     sign_in(result.account)
        #   else
        #     render_error(result.error)
        #   end
        #
        def verify(email: nil, phone: nil, code:, request:, connection: nil, username: nil, allow_registration: true, realm: DEFAULT_REALM, resolve_account: true)
          # Allow callers to use connection:/username: instead of email:/phone:
          if connection.present?
            if username.blank?
              raise StandardId::InvalidRequestError, "username: is required when connection: is provided"
            end

            case connection.to_s
            when "email" then email = username
            when "sms"   then phone = username
            else raise StandardId::InvalidRequestError, "Unsupported connection type: #{connection}"
            end
          end

          new(email: email, phone: phone, code: code, request: request, allow_registration: allow_registration, realm: realm, resolve_account: resolve_account).verify
        end
      end

      def initialize(email: nil, phone: nil, code:, request:, allow_registration: true, realm: DEFAULT_REALM, resolve_account: true)
        @code = code.to_s.strip
        @request = request
        @allow_registration = allow_registration
        @realm = realm.to_s
        @resolve_account = resolve_account
        resolve_target_and_channel!(email, phone)
      end

      def verify
        if @code.blank?
          return failure("Code is required", error_code: :blank_code)
        end

        bypass_result = try_bypass
        return bypass_result if bypass_result

        challenge = find_active_challenge

        unless challenge.present?
          # Constant-time compare even when no challenge exists to prevent
          # timing-based enumeration of valid target+realm pairs. We compare
          # the submitted code against a random value of the same digit
          # length so an observer cannot distinguish "no challenge" from
          # "wrong code" by response time.
          fabricated_code = SecureRandom.random_number(10**@code.length.clamp(4, 10)).to_s.rjust(@code.length.clamp(4, 10), "0")
          secure_compare(fabricated_code, @code)
          return failure("Invalid or expired verification code", error_code: :not_found, attempts: 0)
        end

        code_matches = secure_compare(challenge.code, @code)
        attempts = record_failed_attempt(challenge, code_matches)

        unless code_matches
          emit_otp_validation_failed(attempts)

          if attempts >= StandardId.config.passwordless.max_attempts
            return failure("Too many failed attempts. Please request a new code.", error_code: :max_attempts, attempts: attempts)
          end

          return failure("Invalid or expired verification code", error_code: :invalid_code, attempts: attempts)
        end

        # Re-fetch with lock inside a transaction to prevent concurrent use.
        result = nil
        ActiveRecord::Base.transaction do
          locked_challenge = StandardId::CodeChallenge.lock.find(challenge.id)
          unless locked_challenge.active?
            # No OTP_VALIDATION_FAILED event here: the code was correct but the
            # challenge was consumed by a concurrent request — not an attacker
            # guessing codes. Emitting a failure event would be misleading.
            result = failure("Invalid or expired verification code", error_code: :expired, attempts: attempts)
            raise ActiveRecord::Rollback
          end

          account = nil
          if @resolve_account
            strategy = strategy_for(@channel)
            account = resolve_account(strategy)

            unless account
              label = @channel == "sms" ? "phone number" : "email address"
              result = failure("No account found for this #{label}", error_code: :account_not_found)
              raise ActiveRecord::Rollback
            end
          end

          locked_challenge.use!

          result = success(account: account, challenge: locked_challenge)
        end

        raise "BUG: transaction block failed to set result" if result.nil?

        # Emit events after the transaction commits so subscribers never see
        # events for rolled-back state. Skip auth-oriented events when the
        # caller opted out of account resolution (non-auth realms).
        if result.success? && @resolve_account
          emit_otp_validated(result.account, result.challenge)
        end

        result
      rescue ActiveRecord::RecordNotFound
        failure("Invalid or expired verification code", error_code: :expired)
      rescue ActiveRecord::RecordInvalid => e
        failure("Unable to complete verification: #{e.record.errors.full_messages.to_sentence}", error_code: :server_error)
      end

      private

      # When a bypass_code is configured and the submitted code matches,
      # skip the CodeChallenge lookup entirely. This allows E2E testing
      # tools (e.g. Playwright) to verify OTPs without a real challenge.
      #
      # Events are intentionally emitted with bypass: true so audit log
      # subscribers can distinguish bypass logins from real OTP logins.
      def try_bypass
        bypass_code = StandardId.config.passwordless.bypass_code
        return unless bypass_code.present?

        if defined?(Rails) && Rails.env.production?
          raise "STANDARD_ID_BYPASS_CODE must not be set in production"
        end

        return unless secure_compare(bypass_code, @code)

        if @resolve_account
          strategy = strategy_for(@channel)
          account = nil
          ActiveRecord::Base.transaction do
            account = resolve_account(strategy)
          end

          unless account
            label = @channel == "sms" ? "phone number" : "email address"
            return failure("No account found for this #{label}", error_code: :account_not_found)
          end

          StandardId::Events.publish(
            StandardId::Events::OTP_VALIDATED,
            account: account,
            channel: @channel,
            bypass: true
          )

          success(account: account, challenge: nil)
        else
          # Non-account bypass (used by Otp.verify for non-auth realms).
          # We still emit OTP_VALIDATED with bypass: true for audit parity
          # but without an account payload.
          StandardId::Events.publish(
            StandardId::Events::OTP_VALIDATED,
            account: nil,
            channel: @channel,
            realm: @realm,
            bypass: true
          )

          success(account: nil, challenge: nil)
        end
      end

      def resolve_target_and_channel!(email, phone)
        if email.present?
          @target = email.to_s.strip
          @channel = "email"
        elsif phone.present?
          @target = phone.to_s.strip
          @channel = "sms"
        else
          raise StandardId::InvalidRequestError, "Either email: or phone: must be provided"
        end
      end

      def find_active_challenge
        StandardId::CodeChallenge.active
          .where(realm: @realm, channel: @channel, target: @target)
          .order(created_at: :desc)
          .first
      end

      # NOTE: The update! here can raise ActiveRecord::RecordInvalid, which is
      # rescued alongside account-creation errors. This is intentional — both
      # represent unexpected persistence failures and warrant the same response.
      #
      # The SELECT...FOR UPDATE is load-bearing: without it, two concurrent
      # wrong-code submissions would both read attempts=N and both write
      # attempts=N+1, losing a failure and letting an attacker guess past the
      # max_attempts ceiling. We serialize the read-modify-write under a row
      # lock (portable across pg/sqlite) rather than a Postgres-only
      # `jsonb_set(...) update_all` so the test suite still runs on sqlite.
      def record_failed_attempt(challenge, code_matches)
        return 0 if code_matches

        max_attempts = StandardId.config.passwordless.max_attempts
        attempts = 0

        ActiveRecord::Base.transaction do
          locked = StandardId::CodeChallenge.lock.find(challenge.id)
          attempts = (locked.metadata["attempts"] || 0) + 1
          new_metadata = locked.metadata.merge("attempts" => attempts)

          if attempts >= max_attempts && locked.used_at.nil?
            locked.update!(metadata: new_metadata, used_at: Time.current)
          else
            locked.update!(metadata: new_metadata)
          end
        end

        attempts
      end

      def secure_compare(a, b)
        ActiveSupport::SecurityUtils.secure_compare(a.to_s, b.to_s)
      end

      # Resolve the account for the target identifier.
      # When @allow_registration is true, creates a new account if none exists.
      # When false, returns nil if no account is found.
      def resolve_account(strategy)
        if @allow_registration
          strategy.find_or_create_account(@target)
        else
          strategy.find_account(@target)
        end
      end

      def strategy_for(channel)
        klass = STRATEGY_MAP[channel]
        raise StandardId::InvalidRequestError, "Unsupported connection type: #{channel}" unless klass
        klass.new(@request)
      end

      def emit_otp_validated(account, challenge)
        StandardId::Events.publish(
          StandardId::Events::OTP_VALIDATED,
          account: account,
          channel: @channel
        )
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_VERIFIED,
          code_challenge: challenge,
          account: account,
          channel: @channel
        )
      end

      def emit_otp_validation_failed(attempts)
        StandardId::Events.publish(
          StandardId::Events::OTP_VALIDATION_FAILED,
          identifier: @target,
          channel: @channel,
          attempts: attempts
        )
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_FAILED,
          identifier: @target,
          channel: @channel,
          attempts: attempts
        )
      end

      def success(account:, challenge:)
        Result.new(
          "success?": true,
          account: account,
          challenge: challenge,
          error: nil,
          error_code: nil,
          attempts: nil
        )
      end

      # attempts is nil on success (not meaningful) and 0 when no challenge was found.
      def failure(error, error_code: nil, attempts: nil)
        Result.new(
          "success?": false,
          account: nil,
          challenge: nil,
          error: error,
          error_code: error_code,
          attempts: attempts
        )
      end
    end
  end
end
