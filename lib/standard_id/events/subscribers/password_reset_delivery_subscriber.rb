module StandardId
  module Events
    module Subscribers
      class PasswordResetDeliverySubscriber < Base
        subscribe_to StandardId::Events::CREDENTIAL_PASSWORD_RESET_INITIATED

        def call(event)
          return unless built_in_delivery?

          email = event[:identifier]
          reset_url = event[:reset_url]

          return if email.blank? || reset_url.blank?

          StandardId::PasswordResetMailer.with(
            email: email,
            reset_url: reset_url
          ).reset_email.deliver_later
        end

        def handle_error(error, event)
          StandardId.logger.error(
            "[StandardId::PasswordResetDelivery] Failed to deliver password reset email " \
            "for #{event[:identifier]}: #{error.message}"
          )
        end

        private

        def built_in_delivery?
          StandardId.config.reset_password.delivery == :built_in
        end
      end
    end
  end
end
