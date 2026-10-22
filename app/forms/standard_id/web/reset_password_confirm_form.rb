module StandardId
  module Web
    class ResetPasswordConfirmForm
      include ActiveModel::Model
      include ActiveModel::Attributes
      include StandardId::PasswordStrength

      attribute :password, :string
      attribute :password_confirmation, :string

      attr_reader :password_credential

      validates :password,
        presence: { message: "cannot be blank" },
        confirmation: { message: "confirmation doesn't match" }

      def initialize(password_credential, params = {})
        @password_credential = password_credential
        super(params)
      end

      def submit
        return false unless valid?

        account = @password_credential.account

        ActiveRecord::Base.transaction do
          @password_credential.update!(password: password, password_confirmation: password_confirmation)
          revoke_access!(account)
        end

        StandardId::Events.publish(
          StandardId::Events::CREDENTIAL_PASSWORD_RESET_COMPLETED,
          credential: @password_credential,
          account: account
        )

        true
      rescue ActiveRecord::RecordInvalid => e
        errors.add(:base, e.record.errors.full_messages.join(", "))
        false
      end

      private

      # Revoke every session (and the refresh tokens under them), then any
      # refresh token with no session (e.g. one minted by a grant flow). Revoking
      # rather than destroying keeps the audit trail and fires SESSION_REVOKED;
      # sessions.destroy_all used to nullify refresh_tokens.session_id
      # (dependent: :nullify), leaving those tokens active after the reset.
      def revoke_access!(account)
        StandardId::Session.revoke_all_for!(account, reason: "password_reset")
        StandardId::RefreshToken.where(account_id: account.id, revoked_at: nil).update_all(revoked_at: Time.current)
      end
    end
  end
end
