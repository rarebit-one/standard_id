module StandardId
  module EmailPassword
    # Sign-up: creates an unverified account with a password credential and
    # emails it a code. No tokens here; those come from Verification.verify!.
    #
    # Re-submitting sign-up for an address whose sign-up was never verified
    # NEVER changes the pending password: overwriting it would let anyone
    # re-register a stranger's pending address with their own password and
    # then ride the owner's code into the account. It is treated like a resend:
    #   * same password as the pending one -> a fresh code is sent;
    #   * different password               -> nothing changes, nothing is sent.
    # Both get the same answer as a brand-new address, so sign-up cannot be used
    # to learn that someone started a sign-up. The owner of a squatted address
    # recovers through forgot-password (the link verifies the address and
    # replaces the password), a social sign-in (see
    # EmailPassword.discard_pending_credentials!), or
    # PurgeUnverifiedEmailSignupsJob.
    #
    # An address that already has a verified password account, or belongs to
    # an account that signs in another way, raises :account_exists /
    # :social_account, unless `c.email_password.reveal_existing_accounts` is
    # false: then it returns normally and the address is emailed
    # (AccountNoticeMailer#existing_account) instead.
    module Registration
      class << self
        # @return [String] the normalised email
        # @raise [StandardId::EmailPasswordError] :invalid_request,
        #   :weak_password, :account_exists, :social_account
        def call(email:, password:, name: nil, request: nil)
          email = EmailPassword.normalize_email(email)
          name = name.to_s.strip
          password = password.to_s
          validate!(email, name, password)

          existing = EmailPassword.find_password_credential(email)
          if existing
            identifier = existing.credential&.identifier
            return existing_account!(email, :account_exists) if identifier.nil? || identifier.verified?

            Verification.issue_code(email, name: name, request: request) if existing.authenticate(password)
            return email
          end

          return existing_account!(email, :social_account) if StandardId::EmailIdentifier.exists?(value: email)

          create_account!(email, name, password, request)
          Verification.issue_code(email, name: name, request: request)
          email
        rescue ActiveRecord::RecordNotUnique
          # Lost a race with a concurrent sign-up for the same address.
          existing_account!(email, :account_exists)
        end

        private

        def validate!(email, name, password)
          config = EmailPassword.config
          details = {}
          details[:name] = ["can't be blank"] if config.require_name && name.blank?
          if name.length > config.name_max_length.to_i
            details[:name] = ["is too long (maximum is #{config.name_max_length} characters)"]
          end
          details[:email] = ["is invalid"] unless EmailPassword.valid_email?(email)
          raise StandardId::EmailPasswordError.new(:invalid_request, details: details) if details.any?

          errors = EmailPassword.password_errors(password, email: email)
          raise StandardId::EmailPasswordError.new(:weak_password, details: { password: errors }) if errors.any?
        end

        def existing_account!(email, code)
          raise StandardId::EmailPasswordError.new(code) if EmailPassword.config.reveal_existing_accounts

          if DailyLimit.consume!(:code_issued, email)
            StandardId::AccountNoticeMailer.with(email: email).existing_account.deliver_later
          end
          email
        end

        def create_account!(email, name, password, request)
          ActiveRecord::Base.transaction do
            StandardId::Events.publish(
              StandardId::Events::ACCOUNT_CREATING,
              account_params: { email: email, name: name.presence }.compact,
              auth_method: "password"
            )

            account = build_account(email, name, request)
            identifier = StandardId::EmailIdentifier.create!(account: account, value: email)
            password_credential = StandardId::PasswordCredential.create!(login: email, password: password)
            StandardId::Credential.create!(identifier: identifier, credentialable: password_credential)

            StandardId::Events.publish(
              StandardId::Events::ACCOUNT_CREATED,
              account: account,
              auth_method: "password",
              source: "email_password_signup"
            )
            StandardId::Events.publish(
              StandardId::Events::CREDENTIAL_PASSWORD_CREATED,
              credential: password_credential,
              account: account
            )
            account
          end
        end

        def build_account(email, name, request)
          creator = EmailPassword.config.account_creator
          if creator.respond_to?(:call)
            account = EmailPassword.call_hook(creator, email: email, name: name.presence, request: request)
            raise StandardId::ConfigurationError, "c.email_password.account_creator must return a persisted account" unless account&.persisted?

            return account
          end

          account_class = StandardId.account_class
          attributes = { email: email, name: name.presence || email.split("@").first }
          account_class.create!(attributes.slice(*account_class.attribute_names.map(&:to_sym)))
        end
      end
    end
  end
end
