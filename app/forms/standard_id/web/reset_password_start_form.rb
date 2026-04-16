module StandardId
  module Web
    class ResetPasswordStartForm
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :email, :string

      validates :email, presence: { message: "Please enter your email address" }, format: { with: URI::MailTo::EMAIL_REGEXP }

      # Constructor accepts the reset URL template so the form is decoupled
      # from routing. Controller supplies `reset_password_confirm_url(token: "{token}")`
      # which contains a literal "{token}" placeholder that the delivery job
      # substitutes with the actual token after account lookup.
      def initialize(attributes = {})
        @reset_url_template = attributes.delete(:reset_url_template) if attributes.is_a?(Hash)
        super
      end

      attr_reader :reset_url_template

      def submit
        return false unless valid?

        # Enqueue the full lookup + token generation + mailer delivery pipeline
        # so the controller response time does not depend on whether an account
        # exists for the submitted email. This closes the user-enumeration
        # timing side channel.
        StandardId::PasswordResetDeliveryJob.perform_later(
          email: email.to_s,
          reset_url_template: reset_url_template.to_s
        )

        true
      end
    end
  end
end
