module StandardId
  module EmailPassword
    # The email + password check for login. Token minting is TokenFlow.
    #
    # An unknown address, a wrong password and an account that signs in only
    # another way all raise one generic :invalid_credentials, so login cannot
    # enumerate accounts. :unverified is only reachable WITH the right
    # password, so it reveals nothing the caller did not already know.
    # Publishes the events Oauth::PasswordFlow does.
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
          failed!(email) unless identifier && password_credential.authenticate(password)

          account = identifier.account
          StandardId::Events.publish(
            StandardId::Events::PASSWORD_VALIDATED,
            account: account,
            credential_id: password_credential.id
          )

          raise StandardId::EmailPasswordError.new(:unverified) unless identifier.verified?

          account
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
