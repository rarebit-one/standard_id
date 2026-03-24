module StandardId
  module Events
    module Subscribers
      class PasswordlessDeliverySubscriber < Base
        subscribe_to StandardId::Events::PASSWORDLESS_CODE_GENERATED

        def call(event)
          return unless built_in_delivery?
          return unless event[:channel] == "email"

          identifier = event[:identifier]
          code = event[:code_challenge]&.code

          return if identifier.blank? || code.blank?

          StandardId::PasswordlessMailer.with(
            email: identifier,
            otp_code: code
          ).otp_email.deliver_later
        end

        def handle_error(error, event)
          StandardId.logger.error(
            "[StandardId::PasswordlessDelivery] Failed to deliver OTP email " \
            "for #{event[:identifier]}: #{error.message}"
          )
        end

        private

        def built_in_delivery?
          StandardId.config.passwordless.delivery == :built_in
        end
      end
    end
  end
end
