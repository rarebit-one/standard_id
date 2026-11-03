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

      # A mistyped TLD (rarebit.ome) is accepted by the ESP and bounces hours
      # later, so the user just never gets a code. Refuse it before sending.
      def validate_recipient!(email)
        error = StandardId::EmailDomain.validation_error(email)
        raise StandardId::InvalidRequestError, error if error
      end

      def find_or_create_account!(email)
        Account.find_or_create_by_verified_email!(email)
      end

      def find_existing_account(email)
        normalized = email.to_s.strip.downcase
        identifier = StandardId::EmailIdentifier.includes(:account).find_by(value: normalized)
        identifier&.account
      end
    end
  end
end
