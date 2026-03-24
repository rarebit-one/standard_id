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
        emit_code_requested(username)
        challenge = create_challenge!(username)
        emit_code_generated(challenge, username)
        sender_callback&.call(username, challenge.code)
        emit_code_sent(username)
        challenge
      end

      protected

      def create_challenge!(username)
        code = generate_otp_code

        cc = StandardId::CodeChallenge.create!(
          realm: "authentication",
          channel: connection_type,
          target: username,
          code: code,
          expires_at: StandardId.config.passwordless.code_ttl.seconds.from_now,
          ip_address: StandardId::Utils::IpNormalizer.normalize(request.remote_ip),
          user_agent: request.user_agent
        )
        cc
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

      def find_existing_account(_username)
        raise NotImplementedError
      end

      public

      # Public wrapper to reuse account lookup/creation outside OTP verification.
      # When a custom account_factory is configured, delegates to it instead of
      # the built-in find_or_create_account! logic.
      def find_or_create_account(username)
        validate_username!(username)

        factory = StandardId.config.passwordless.account_factory
        if factory.respond_to?(:call)
          factory.call(
            email: username,
            params: request_params,
            request: request
          )
        else
          find_or_create_account!(username)
        end
      end

      # Public wrapper to look up an existing account without creating one.
      # Returns nil if no account is found for the given username.
      def find_account(username)
        validate_username!(username)
        find_existing_account(username)
      end

      def identifier_class
        raise NotImplementedError
      end

      def sender_callback
        # Implement in subclasses
        nil
      end

      private

      # Extract request parameters safely. Returns an empty hash if the request
      # does not support parameters (e.g. test doubles).
      def request_params
        return {} unless request.respond_to?(:params)
        request.params
      end

      def emit_code_requested(username)
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_REQUESTED,
          identifier: username,
          channel: connection_type
        )
      end

      def emit_code_generated(challenge, username)
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_GENERATED,
          code_challenge: challenge,
          identifier: username,
          channel: connection_type,
          expires_at: challenge.expires_at
        )
      end

      def emit_code_sent(username)
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_SENT,
          identifier: username,
          channel: connection_type,
          delivery_status: "sent"
        )
      end
    end
  end
end
