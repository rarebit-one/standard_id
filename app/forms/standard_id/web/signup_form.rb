module StandardId
  module Web
    class SignupForm
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :email, :string
      attribute :password, :string
      attribute :password_confirmation, :string

      attr_reader :account

      validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
      validates :password, presence: true, length: { minimum: 8 }, confirmation: true

      def submit
        return false unless valid?

        emit_account_creating

        ActiveRecord::Base.transaction do
          @account = Account.create!(account_params)

          password_credential = StandardId::PasswordCredential.create!(
            password_credential_params.merge(
              credential_attributes: {
                identifier_attributes: email_identifier_params.merge(account: @account)
              }
            )
          )

          emit_account_created
          emit_credential_created(password_credential)
        end

        true
      rescue ActiveRecord::RecordInvalid => e
        errors.add(:base, e.record.errors.full_messages.join(", "))
        false
      rescue ActiveRecord::RecordNotUnique
        errors.add(:base, "An account with this email already exists")
        false
      end

      private

      def emit_account_creating
        StandardId::Events.publish(
          StandardId::Events::ACCOUNT_CREATING,
          account_params: account_params,
          auth_method: "password"
        )
      end

      def emit_account_created
        StandardId::Events.publish(
          StandardId::Events::ACCOUNT_CREATED,
          account: @account,
          auth_method: "password",
          source: "signup"
        )
      end

      def emit_credential_created(password_credential)
        StandardId::Events.publish(
          StandardId::Events::CREDENTIAL_PASSWORD_CREATED,
          credential: password_credential,
          account: @account
        )
      end

      def account_params
        { name: (email.to_s.split("@").first.presence || "User"), email: }
      end

      def email_identifier_params
        { type: "StandardId::EmailIdentifier", value: email }
      end

      def password_credential_params
        { login: email, password: }
      end
    end
  end
end
