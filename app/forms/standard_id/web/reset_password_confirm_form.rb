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

        # The password change and the revocation commit together, so a failure
        # cannot leave the new password in place with old tokens still live.
        # The SESSION_REVOKED events revoke_all_for! publishes therefore run
        # before the commit; each is rescued, so a subscriber cannot roll the
        # reset back, but one that reads the rows must do so after commit
        # (e.g. from a job, which Rails enqueues after commit).
        ActiveRecord::Base.transaction do
          @password_credential.update!(password: password, password_confirmation: password_confirmation)
          revoke_access!(account)
        end

        publish_reset_completed(account)

        true
      rescue ActiveRecord::RecordInvalid => e
        errors.add(:base, e.record.errors.full_messages.join(", "))
        false
      end

      private

      # The reset has already happened, so a failing subscriber must not turn
      # it into an error page; report and carry on, as Session does for
      # SESSION_REVOKED.
      def publish_reset_completed(account)
        StandardId::Events.publish(
          StandardId::Events::CREDENTIAL_PASSWORD_RESET_COMPLETED,
          credential: @password_credential,
          account: account
        )
      rescue StandardError => e
        Rails.error.report(e, handled: true, source: "standard_id")
        logger = StandardId.logger
        return unless logger.respond_to?(:error)

        logger.error(
          "[StandardId::Web::ResetPasswordConfirmForm] Failed to publish " \
          "CREDENTIAL_PASSWORD_RESET_COMPLETED for account #{account.id}: #{e.class}: #{e.message}"
        )
      end

      # Revoke every session and refresh token (StandardId::AccessRevocation).
      # Revoking rather than destroying keeps the audit trail and fires
      # SESSION_REVOKED; sessions.destroy_all used to nullify
      # refresh_tokens.session_id (dependent: :nullify), leaving those tokens
      # active after the reset.
      def revoke_access!(account)
        StandardId::AccessRevocation.revoke_all!(account, reason: "password_reset")
      end
    end
  end
end
