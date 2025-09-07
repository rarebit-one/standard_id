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

        ActiveRecord::Base.transaction do
          @account = Account.create!(account_params)
          StandardId::PasswordCredential.create!(
            password_credential_params.merge(
              credential_attributes: {
                identifier_attributes: email_identifier_params.merge(account: @account)
              }
            )
          )
        end

        true
      rescue ActiveRecord::RecordInvalid => e
        errors.add(:base, e.record.errors.full_messages.join(", "))
        false
      rescue ActiveRecord::RecordNotUnique => e
        errors.add(:base, e.message)
        false
      end

      private

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
