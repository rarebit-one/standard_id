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
    #
    # ACCOUNT_CREATED and CREDENTIAL_PASSWORD_CREATED fire here, inside the
    # sign-up transaction, for an account whose address is NOT yet verified
    # (as they do for Web::SignupForm). Provision anything that should wait for
    # a proven address from `c.email_password.after_email_verified` instead.
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
            return existing_account!(email, :account_exists, password) if identifier.nil? || identifier.verified?

            Verification.issue_code(email, name: name, request: request) if existing.authenticate(password)
            return email
          end

          return existing_account!(email, :social_account, password) if StandardId::EmailIdentifier.exists?(value: email)

          create_account!(email, name, password, request)
          Verification.issue_code(email, name: name, request: request)
          email
        rescue ActiveRecord::RecordNotUnique
          # Lost a race with a concurrent sign-up for the same address.
          existing_account!(email, :account_exists)
        rescue ActiveRecord::RecordInvalid => e
          # The same race, caught by the uniqueness validation instead.
          return existing_account!(email, :account_exists) if e.record.errors.of_kind?(:login, :taken)

          # A host Account validation (or account_creator) refused the record.
          raise StandardId::EmailPasswordError.new(:invalid_request, details: e.record.errors.to_hash)
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

        # +password+ is hashed and thrown away when concealing: a new address
        # pays one bcrypt to store its password, so an existing one must too,
        # or the response time would tell them apart.
        def existing_account!(email, code, password = nil)
          raise StandardId::EmailPasswordError.new(code) if EmailPassword.config.reveal_existing_accounts

          StandardId::PasswordCredential.new(password: password) unless password.nil?
          if DailyLimit.consume!(:code_issued, email)
            StandardId::AccountNoticeMailer.with(email: email).existing_account.deliver_later
          end
          email
        end

        def create_account!(email, name, password, request)
          EmailPassword.require_signup_source_column!
          ActiveRecord::Base.transaction do
            StandardId::Events.publish(
              StandardId::Events::ACCOUNT_CREATING,
              account_params: { email: email, name: name.presence }.compact,
              auth_method: "password"
            )

            account = build_account(email, name, request)
            identifier = StandardId::EmailIdentifier.create!(
              account: account, value: email, signup_source: EmailPassword::SIGNUP_SOURCE
            )
            password_credential = StandardId::PasswordCredential.create!(login: email, password: password)
            # Created through the association, not Credential.create!: the
            # has_one's touch: true reads password_credential.credential in
            # after_create, caching nil, so a subscriber walking
            # credential.identifier.account would get nil. Going through the
            # association leaves the whole chain loaded in memory, which also
            # keeps strict-loading hosts from lazily loading identifier/account.
            password_credential.create_credential!(identifier: identifier)

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
