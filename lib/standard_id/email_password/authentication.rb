module StandardId
  module EmailPassword
    # The email + password check for login. Token minting is TokenFlow.
    #
    # An unknown address, a wrong password and an account that signs in only
    # another way all raise one generic :invalid_credentials, so login cannot
    # enumerate accounts. :unverified is only reachable WITH the right
    # password, so it reveals nothing the caller did not already know.
    # Publishes the events Oauth::PasswordFlow does.
    #
    # Given a block, yields the account with the password credential's row
    # locked, after re-checking that the password has not changed since it was
    # verified. Mint tokens inside it: PasswordReset.complete! takes the same
    # lock to change the password and revoke access, so a login racing a reset
    # either finishes first (and its tokens are revoked) or fails.
    module Authentication
      class << self
        # @return [Account]
        # @raise [StandardId::EmailPasswordError] :invalid_credentials, :unverified
        def call(email:, password:)
          email = EmailPassword.normalize_email(email)
          password = password.to_s

          StandardId::Events.publish(
            StandardId::Events::AUTHENTICATION_ATTEMPT_STARTED,
            account_lookup: email,
            auth_method: "password"
          )

          password_credential = EmailPassword.find_password_credential(email)
          unless password_credential
            BCrypt::Password.new(DUMMY_PASSWORD_DIGEST.value).is_password?(password)
            failed!(email)
          end

          identifier = password_credential.credential&.identifier
          verified_digest = password_credential.password_digest
          failed!(email) unless identifier && password_credential.authenticate(password)

          account = identifier.account
          StandardId::Events.publish(
            StandardId::Events::PASSWORD_VALIDATED,
            account: account,
            credential_id: password_credential.id
          )

          raise StandardId::EmailPasswordError.new(:unverified) unless identifier.verified?
          return account unless block_given?

          password_credential.with_lock do
            failed!(email) unless password_credential.password_digest == verified_digest
            yield account
          end
        end

        private

        def failed!(email)
          StandardId::Events.publish(
            StandardId::Events::AUTHENTICATION_FAILED,
            account_lookup: email,
            auth_method: "password",
            error_code: "invalid_credentials",
            error_message: "Invalid email or password"
          )
          raise StandardId::EmailPasswordError.new(:invalid_credentials)
        end
      end
    end
  end
end
