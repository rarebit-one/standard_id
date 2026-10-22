module StandardId
  module EmailPassword
    # Forgot-password and the reset it leads to.
    module PasswordReset
      class TokenAlreadyUsed < StandardError; end

      class << self
        # Queues the reset email for +email+. The lookup, the token and the
        # CREDENTIAL_PASSWORD_RESET_INITIATED event all happen in
        # PasswordResetDeliveryJob, so the request path is identical whether or
        # not the address has an account. Delivery follows
        # reset_password.delivery.
        #
        # Daily caps, counted whether or not the address has an account:
        # rate_limits.email_password_reset_requests_per_network_per_day per
        # address per client key, so an attacker who burns their own allowance
        # does not stop the owner, elsewhere, from getting a link; and
        # email_password_reset_requests_per_day per address overall. The
        # network cap is checked first, so requests it refuses never spend the
        # shared ceiling.
        #
        # @return [void]
        def request(email:, request: nil)
          email = EmailPassword.normalize_email(email)
          return if email.blank?

          url_template = reset_url_template(request)
          client_key = EmailPassword.client_key(request)
          return if DailyLimit.exceeded?(:reset_requested_network, email, scope: client_key)
          return unless DailyLimit.consume!(:reset_requested, email)

          DailyLimit.record!(:reset_requested_network, email, scope: client_key)
          StandardId::PasswordResetDeliveryJob.perform_later(email: email, reset_url_template: url_template)
        end

        # Whether +token+ still resolves (not expired, used or tampered with).
        def valid_token?(token)
          find_credential(token).present?
        end

        # Sets a new password from a reset token, verifies the address and
        # revokes every session and refresh token (AccessRevocation).
        #
        # A reset that verifies a pending sign-up is its first verification, so
        # it runs `c.email_password.after_email_verified` too, in the same
        # transaction (EmailPassword.complete_verification!): if the hook
        # raises, nothing changes and the token still works.
        #
        # The token is PasswordCredential's `generates_token_for
        # :password_reset`: it embeds the current digest, so the change below is
        # what makes it single-use. That holds under concurrency too: the row is
        # locked and the token re-resolved inside the transaction, so of two
        # requests racing with one token, the second sees the new digest.
        #
        # @param password_confirmation [String, nil] compared when given
        # @return [Account]
        # @raise [StandardId::EmailPasswordError] :invalid_reset_token,
        #   :weak_password
        def complete!(token:, password:, password_confirmation: nil, request: nil)
          password = password.to_s
          password_credential = find_credential(token)
          identifier = password_credential&.credential&.identifier
          raise StandardId::EmailPasswordError.new(:invalid_reset_token) if identifier.nil?

          validate!(password, password_confirmation, password_credential.login)

          account = identifier.account
          issued_for_digest = password_credential.password_digest

          ActiveRecord::Base.transaction do
            password_credential.lock!
            unless password_credential.password_digest == issued_for_digest &&
                find_credential(token)&.id == password_credential.id
              raise TokenAlreadyUsed
            end

            password_credential.update!(password: password)
            # Skip the name lookup when the address was verified already.
            name = EmailPassword.signup_name(password_credential.login) unless identifier.verified?
            EmailPassword.complete_verification!(identifier, name: name, request: request)
            StandardId::AccessRevocation.revoke_all!(account, reason: "password_reset")
          end

          publish_reset_completed(account, password_credential)
          account
        rescue TokenAlreadyUsed
          raise StandardId::EmailPasswordError.new(:invalid_reset_token)
        end

        private

        def find_credential(token)
          return nil if token.blank?

          StandardId::PasswordCredential
            .includes(credential: { identifier: :account })
            .find_by_token_for(:password_reset, token.to_s)
        end

        def validate!(password, password_confirmation, login)
          # has_secure_password ignores an empty assignment on an existing
          # record, which would "succeed" without changing anything.
          errors = password.empty? ? ["can't be blank"] : EmailPassword.password_errors(password, email: login)
          details = {}
          details[:password] = errors if errors.any?
          if !password_confirmation.nil? && password_confirmation.to_s != password
            details[:password_confirmation] = ["doesn't match Password"]
          end
          raise StandardId::EmailPasswordError.new(:weak_password, details: details) if details.any?
        end

        def reset_url_template(request)
          setting = EmailPassword.config.reset_url
          template = setting.respond_to?(:call) ? EmailPassword.call_hook(setting, request: request) : setting
          return template.to_s if template.to_s.include?("{token}")

          raise StandardId::ConfigurationError,
            "c.email_password.reset_url must be a URL containing \"{token}\" (or a callable (request:) returning one), " \
            "e.g. \"https://app.example.com/password-reset?token={token}\"."
        end

        # The reset has already happened, so a failing subscriber must not turn
        # it into an error; log and carry on, as Web::ResetPasswordConfirmForm does.
        def publish_reset_completed(account, password_credential)
          StandardId::Events.publish(
            StandardId::Events::CREDENTIAL_PASSWORD_RESET_COMPLETED,
            credential: password_credential,
            account: account
          )
        rescue StandardError => e
          logger = StandardId.logger
          return unless logger.respond_to?(:error)

          logger.error(
            "[StandardId::EmailPassword::PasswordReset] Failed to publish " \
            "CREDENTIAL_PASSWORD_RESET_COMPLETED for account #{account.id}: #{e.class}: #{e.message}"
          )
        end
      end
    end
  end
end
