module StandardId
  module Passwordless
    class EmailStrategy < BaseStrategy
      def connection_type
        "email"
      end

      private

      def validate_username!(email)
        raise StandardId::InvalidRequestError, "Invalid email format" unless email.to_s.match?(/\A[^@\s]+@[^@\s]+\z/)
      end

      def find_or_create_account!(email)
        identifier = StandardId::EmailIdentifier.includes(:account).find_by(value: email)
        return identifier.account if identifier.present?

        identifiers_attributes = [{ type: "StandardId::EmailIdentifier", value: email, verified_at: Time.current }]
        Account.create!(identifiers_attributes:)
      end

      def sender_callback
        StandardId.config.passwordless_email_sender
      end
    end
  end
end
