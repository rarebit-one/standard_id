module StandardId
  module Passwordless
    class SmsStrategy < BaseStrategy
      def connection_type
        "sms"
      end

      private

      def validate_username!(phone_number)
        unless phone_number.to_s.match?(/\A\+?[1-9]\d{1,14}\z/)
          raise StandardId::InvalidRequestError, "Invalid phone number format"
        end
      end

      def find_or_create_account!(phone_number)
        identifier = StandardId::PhoneNumberIdentifier.includes(:account).find_by(value: phone_number)
        return identifier.account if identifier.present?

        identifiers_attributes = [{ type: "StandardId::PhoneNumberIdentifier", value: phone_number, verified_at: Time.current }]
        Account.create!(identifiers_attributes:)
      end

      def sender_callback
        StandardId.config.passwordless_sms_sender
      end
    end
  end
end
