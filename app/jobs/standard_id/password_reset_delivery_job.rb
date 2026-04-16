module StandardId
  # Handles the full password-reset email delivery pipeline asynchronously.
  #
  # Running this work in a job (rather than inline in the request) eliminates
  # the timing side-channel that would otherwise leak whether an account
  # exists for a given email: every request enqueues the same job, so the
  # synchronous request path is constant-time regardless of account state.
  class PasswordResetDeliveryJob < ApplicationJob
    queue_as :default

    # @param email [String] the raw email submitted by the user
    # @param reset_url_template [String] URL with a literal "{token}" placeholder
    #   that the job will substitute with the generated reset token
    def perform(email:, reset_url_template:)
      return unless StandardId.config.reset_password.delivery == :built_in

      normalized = email.to_s.strip.downcase
      return if normalized.blank?

      identifier = StandardId::EmailIdentifier.find_by(value: normalized)
      return if identifier.nil?

      password_credential = identifier.account
        &.credentials
        &.where(credentialable_type: "StandardId::PasswordCredential")
        &.first
        &.credentialable
      return if password_credential.nil?

      token = password_credential.generate_token_for(:password_reset)
      return if token.blank?

      reset_url = reset_url_template.to_s.sub("{token}", token)

      StandardId::Events.publish(
        StandardId::Events::CREDENTIAL_PASSWORD_RESET_INITIATED,
        account: identifier.account,
        identifier: normalized
      )

      StandardId::PasswordResetMailer.with(
        email: normalized,
        reset_url: reset_url
      ).reset_email.deliver_later
    end
  end
end
