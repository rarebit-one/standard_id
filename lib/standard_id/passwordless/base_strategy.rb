module StandardId
  module Passwordless
    class BaseStrategy
      attr_reader :request

      def initialize(request)
        @request = request
      end

      def connection_type
        raise NotImplementedError
      end

      # Start flow: validate recipient, create challenge, and trigger sender
      # attrs: { connection:, username: }
      def start!(attrs)
        username = attrs[:username]
        validate_username!(username)
        challenge = create_challenge!(username)
        sender_callback&.call(username, challenge.code)
        challenge
      end

      protected

      def create_challenge!(username)
        StandardId::PasswordlessChallenge.create!(
          connection_type: connection_type,
          username: username,
          code: generate_otp_code,
          expires_at: 10.minutes.from_now,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
      end

      def generate_otp_code
        (SecureRandom.random_number(900_000) + 100_000).to_s
      end

      def validate_username!(_username)
        raise NotImplementedError
      end

      def find_or_create_account!(_username)
        raise NotImplementedError
      end

      public

      # Public wrapper to reuse account lookup/creation outside OTP verification
      def find_or_create_account(username)
        validate_username!(username)
        find_or_create_account!(username)
      end

      def identifier_class
        raise NotImplementedError
      end

      def sender_callback
        # Implement in subclasses
        nil
      end
    end
  end
end
