module StandardId
  module Passwordless
    class BaseStrategy
      attr_reader :request, :realm

      def initialize(request, realm: StandardId::Passwordless::DEFAULT_REALM)
        @request = request
        @realm = realm.to_s
      end

      def connection_type
        raise NotImplementedError
      end

      # Start flow: validate recipient, create challenge, and trigger sender
      # attrs: { connection:, username:, code_length:, expires_in:, metadata:, skip_sender: }
      def start!(attrs)
        username = attrs[:username]
        code_length = attrs[:code_length]
        expires_in = attrs[:expires_in]
        metadata = attrs[:metadata] || {}
        skip_sender = attrs[:skip_sender] == true

        validate_username!(username)
        run_username_validator!(username)
        emit_code_requested(username)
        challenge = create_challenge!(
          username,
          code_length: code_length,
          expires_in: expires_in,
          metadata: metadata
        )
        # skip_sender is forwarded into the event payload so subscribers that
        # deliver on PASSWORDLESS_CODE_GENERATED (e.g. PasswordlessDeliverySubscriber)
        # can honor a per-call manual-delivery request — not just the legacy
        # sender_callback. Without this, Otp.issue(delivery: :manual) silently
        # double-delivers when c.passwordless.delivery == :built_in.
        emit_code_generated(challenge, username, skip_sender: skip_sender)
        sender_callback&.call(username, challenge.code) unless skip_sender
        emit_code_sent(username) unless skip_sender
        challenge
      end

      protected

      def create_challenge!(username, code_length: nil, expires_in: nil, metadata: {})
        ActiveRecord::Base.transaction do
          invalidate_active_challenges!(username)

          code = generate_otp_code(code_length: code_length)
          ttl  = expires_in || StandardId.config.passwordless.code_ttl.seconds

          StandardId::CodeChallenge.create!(
            realm: @realm,
            channel: connection_type,
            target: username,
            code: code,
            expires_at: ttl.from_now,
            ip_address: StandardId::Utils::IpNormalizer.normalize(request.remote_ip),
            user_agent: request.user_agent,
            metadata: metadata
          )
        end
      end

      # Uses update_all for a single UPDATE statement (no N+1). This bypasses
      # ActiveRecord callbacks intentionally — CodeChallenge has no after-save
      # hooks today. If callbacks are added to CodeChallenge#use!, revisit this.
      def invalidate_active_challenges!(username)
        StandardId::CodeChallenge.active
          .where(realm: @realm, channel: connection_type, target: username)
          .update_all(used_at: Time.current)
      end

      # Generate a zero-padded numeric OTP code. When `code_length:` is
      # provided (explicit per-call override used by Otp.issue callers) it
      # must be between 4 and 10 and overrides the configured default.
      # Otherwise delegates to StandardId::Passwordless.generate_otp_code,
      # which reads config.passwordless.code_length (default 6, clamped
      # to 4..10).
      def generate_otp_code(code_length: nil)
        return StandardId::Passwordless.generate_otp_code if code_length.nil?

        length = code_length.to_i
        raise StandardId::InvalidRequestError, "code_length must be between 4 and 10" unless length.between?(4, 10)

        SecureRandom.random_number(10**length).to_s.rjust(length, "0")
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
          account = factory.call(
            identifier: username,
            params: request_params,
            request: request
          )
          raise StandardId::InvalidRequestError, "account_factory must return an account" unless account.present?
          account
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

      def run_username_validator!(username)
        validator = StandardId.config.passwordless.username_validator
        return unless validator.respond_to?(:call)

        error = validator.call(username, connection_type)
        raise StandardId::InvalidRequestError, error if error.present?
      end

      def emit_code_requested(username)
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_REQUESTED,
          identifier: username,
          channel: connection_type,
          realm: @realm
        )
      end

      def emit_code_generated(challenge, username, skip_sender: false)
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_GENERATED,
          code_challenge: challenge,
          identifier: username,
          channel: connection_type,
          realm: @realm,
          expires_at: challenge.expires_at,
          skip_sender: skip_sender
        )
      end

      def emit_code_sent(username)
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_SENT,
          identifier: username,
          channel: connection_type,
          realm: @realm,
          delivery_status: "sent"
        )
      end
    end
  end
end
