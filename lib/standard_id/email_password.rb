require "concurrent/delay"

module StandardId
  # Email + password sign-up and sign-in for JSON clients
  # (Api::EmailPasswordController), switched on with
  # `c.email_password.enabled = true`.
  #
  # Built on the engine's primitives rather than beside them: PasswordCredential
  # (has_secure_password, PasswordStrength, the single-use password_reset token),
  # StandardId::Otp for the 6-digit sign-up code, PasswordResetDeliveryJob for
  # forgot-password, and a TokenGrantFlow (EmailPassword::TokenFlow) for tokens,
  # so a sign-in here returns the same TokenResponse as the other grants and
  # refreshes through /oauth/token.
  #
  # The rules:
  #   * Sign-up creates an UNVERIFIED account and emails a code. Tokens are
  #     issued only once the code is confirmed, together with the sign-up
  #     password: the code proves the inbox, the password proves the caller is
  #     whoever started this sign-up.
  #   * Login with the right password on an unverified address answers
  #     :unverified, so the client can send the user to its verify screen.
  #     Every other login failure is one generic :invalid_credentials.
  #   * Re-submitting sign-up for a pending address never changes its password.
  #   * Resend and forgot-password always answer the same, whatever the address.
  #   * A reset link sets the password, verifies the address (following the
  #     link proves the inbox) and revokes every session and refresh token.
  #
  # Each operation returns its result and raises StandardId::EmailPasswordError
  # otherwise, so a host can drive them from its own controllers too.
  module EmailPassword
    # A digest to compare against when no credential exists, so a miss costs
    # the same bcrypt work as a hit and timing does not reveal whether the
    # address is registered.
    DUMMY_PASSWORD_DIGEST = Concurrent::Delay.new { BCrypt::Password.create("").freeze }

    class << self
      def config
        StandardId.config.email_password
      end

      def enabled?
        config.enabled == true
      end

      def normalize_email(email)
        email.to_s.strip.downcase
      end

      def valid_email?(email)
        StandardId::EmailIdentifier::EMAIL_FORMAT.match?(email.to_s)
      end

      # The password credential whose login is +email+, with the identifier and
      # account it hangs off preloaded.
      def find_password_credential(email)
        StandardId::PasswordCredential
          .includes(credential: { identifier: :account })
          .find_by(login: normalize_email(email))
      end

      # The pending sign-up for +email+ when +password+ is its password: the
      # identifier of an unverified password credential, else nil. A miss still
      # pays for a bcrypt comparison.
      def pending_identifier(email, password)
        identifier = identifier_for_password(email, password)
        identifier unless identifier.nil? || identifier.verified?
      end

      # The identifier of the password credential for +email+, only when
      # +password+ is that credential's password.
      def identifier_for_password(email, password)
        password = password.to_s
        password_credential = find_password_credential(email)
        unless password_credential
          BCrypt::Password.new(DUMMY_PASSWORD_DIGEST.value).is_password?(password)
          return nil
        end
        return nil if password.empty? || !password_credential.authenticate(password)

        password_credential.credential&.identifier
      end

      # Field messages for +password+ (empty when acceptable): PasswordStrength
      # and has_secure_password's own checks on an unsaved probe, then
      # `c.email_password.password_validator`, only once those pass.
      def password_errors(password, email: nil)
        probe = StandardId::PasswordCredential.new(login: email.presence || "probe@example.invalid", password: password)
        probe.validate
        errors = probe.errors.messages_for(:password)
        return errors if errors.any?

        validator = config.password_validator
        return [] unless validator.respond_to?(:call)

        Array(call_hook(validator, password: password, email: email)).compact.map(&:to_s)
      end

      # The key per-IP limits count under (`c.email_password.client_key`).
      def client_key(request)
        hook = config.client_key
        key = call_hook(hook, request: request) if hook.respond_to?(:call)
        key.presence || request&.remote_ip.to_s
      end

      # Pre-account-takeover defence for hosts that link social sign-ins by
      # email (c.social.link_strategy = :trust_provider). If someone started a
      # sign-up for an address they do not own and never confirmed it, the
      # owner signing in with a provider would land in THAT account with the
      # stranger's password attached. The password was never usable (login
      # needs the code, which only reaches the owner), but it is one reset away
      # from becoming so. Drop it: the provider sign-in proved the address, the
      # pending sign-up proved nothing.
      #
      # When anything was discarded, every session and refresh token the
      # account already held is revoked as well: whatever was issued before
      # the owner proved the address was issued to someone who had not.
      # SOCIAL_ACCOUNT_LINKED fires after the social flow has issued its own
      # session or tokens, so pass +issued_before+ (when that login started) to
      # spare them. Call it from a SOCIAL_ACCOUNT_LINKED subscriber.
      #
      # @return [Integer] the number of pending credentials discarded
      def discard_pending_credentials!(account, issued_before: nil)
        return 0 if account.nil?

        discarded = 0
        StandardId::Credential
          .joins(:identifier)
          .where(standard_id_identifiers: { account_id: account.id, verified_at: nil })
          .where(credentialable_type: StandardId::PasswordCredential.name)
          .find_each do |credential|
            ActiveRecord::Base.transaction do
              password_credential = StandardId::PasswordCredential.find_by(id: credential.credentialable_id)
              credential.destroy!
              password_credential&.destroy!
            end
            discarded += 1
          end

        if discarded.positive?
          StandardId::AccessRevocation.revoke_all!(account, reason: "pending_signup_discarded", issued_before: issued_before)
        end
        discarded
      end

      def call_hook(hook, **context)
        hook.call(**StandardId::Utils::CallableParameterFilter.filter(hook, context))
      end
    end
  end
end
