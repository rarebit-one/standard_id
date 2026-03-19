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
        Account.find_or_create_by_verified_email!(email)
      end

      def sender_callback
        StandardId.config.passwordless_email_sender
      end
    end
  end
end
