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

      # Start flow: validate recipient, create challenge, and publish
      # PASSWORDLESS_CODE_GENERATED — delivery happens in a subscriber to that
      # event (the engine's PasswordlessDeliverySubscriber when
      # c.passwordless.delivery == :built_in, otherwise the host's own).
      #
      # attrs: { connection:, username:, code_length:, expires_in:, metadata:, skip_sender:, delivery: }
      #
      # +delivery+ (:built_in / :custom / :manual, or nil when not called via
      # StandardId::Otp.issue) is forwarded in the event payload; see
      # Otp.issue for what each value means to the subscribers.
      def start!(attrs)
        username = attrs[:username]
        code_length = attrs[:code_length]
        expires_in = attrs[:expires_in]
        metadata = attrs[:metadata] || {}
        skip_sender = attrs[:skip_sender] == true
        delivery = attrs[:delivery]&.to_sym

        validate_username!(username)
        run_username_validator!(username)
        enforce_start_rate_limits!(username)
        # Cooldown check and challenge creation in ONE transaction, serialised
        # per target (see #lock_target!), so two concurrent starts for the same
        # address cannot both pass the check and both issue a code — which
        # invalidated the first code the moment the second was created and
        # left the user holding a dead one (fundbright delivery-ops#345).
        challenge = ActiveRecord::Base.transaction do
          lock_target!(username)
          enforce_retry_delay!(username)
          create_challenge!(
            username,
            code_length: code_length,
            expires_in: expires_in,
            metadata: metadata
          )
        end
        # Published once the row is committed: a subscriber that writes must
        # not have its work rolled back with a failed insert, nor hold the
        # per-target lock for its whole runtime. Still before CODE_GENERATED.
        emit_code_requested(username)
        # skip_sender is forwarded into the event payload so subscribers that
        # deliver on PASSWORDLESS_CODE_GENERATED (e.g. PasswordlessDeliverySubscriber)
        # can honor a per-call manual-delivery request. Without this,
        # Otp.issue(delivery: :manual) silently double-delivers when
        # c.passwordless.delivery == :built_in.
        generated_payload = emit_code_generated(challenge, username, skip_sender: skip_sender, delivery: delivery)
        emit_code_sent(username, delivery_status: delivery_status_for(challenge, generated_payload)) unless skip_sender
        challenge
      end

      protected

      # Per-target and per-IP ceilings on starts (rate_limits.otp_start_per_*),
      # counted here rather than on a controller so they hold whichever way a
      # host reaches the strategy. The target key carries the realm and
      # channel, so an authentication code and a verification code for the
      # same address are separate budgets, as they are separate challenges.
      def enforce_start_rate_limits!(username)
        limits = StandardId.config.rate_limits
        target = username.to_s.strip.downcase
        StandardId::RateLimiter.hit!(
          "standard_id:otp-start:target:#{@realm}:#{connection_type}:#{target}",
          limit: limits.otp_start_per_target, window: 15.minutes
        )

        ip = request.respond_to?(:remote_ip) ? request.remote_ip : nil
        return if ip.blank?

        StandardId::RateLimiter.hit!(
          "standard_id:otp-start:ip:#{StandardId::Utils::IpNormalizer.normalize(ip)}",
          limit: limits.otp_start_per_ip, window: 1.hour
        )
      end

      # Serialise concurrent starts for one (realm, channel, target) for the
      # rest of the enclosing transaction. On PostgreSQL this is a transaction-
      # scoped advisory lock, released at commit or rollback, so a second start
      # waits for the first to finish and then sees the challenge it created.
      # Other adapters get no cross-process lock: the retry-delay check there
      # stays what it was, a read followed by a write. Keyed on the normalised
      # target (as the rate limit is), so "User@x" and "user@x" contend for one
      # lock even when a caller skipped the web login's own downcasing.
      def lock_target!(username)
        connection = StandardId::CodeChallenge.connection
        return unless connection.adapter_name.match?(/postg/i)

        key = "standard_id:otp:#{@realm}:#{connection_type}:#{username.to_s.strip.downcase}"
        connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(key)}))")
      end

      # Reject a resend that arrives within passwordless.retry_delay seconds of
      # the most recent still-active code for this target. A soft cooldown that
      # complements the coarser per-target rate limits: it does not consume the
      # active challenge, so the code already sent remains usable. Raises
      # InvalidRequestError (rescued by the web login + API OAuth error handlers).
      def enforce_retry_delay!(username)
        delay = StandardId::Passwordless.retry_delay
        return if delay <= 0

        last = StandardId::CodeChallenge.active
          .where(realm: @realm, channel: connection_type, target: username)
          .order(created_at: :desc)
          .first
        return if last.nil?

        elapsed = Time.current - last.created_at
        return if elapsed >= delay

        wait = (delay - elapsed).ceil
        raise StandardId::RetryDelayError.new(
          "Please wait #{wait} #{'second'.pluralize(wait)} before requesting another code",
          retry_after: wait
        )
      end

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

      # @return [Hash] the published payload (used to decide the delivery status)
      def emit_code_generated(challenge, username, skip_sender: false, delivery: nil)
        payload = {
          code_challenge: challenge,
          identifier: username,
          channel: connection_type,
          realm: @realm,
          expires_at: challenge.expires_at,
          skip_sender: skip_sender,
          delivery: delivery
        }
        StandardId::Events.publish(StandardId::Events::PASSWORDLESS_CODE_GENERATED, payload)
        payload
      end

      # delivery_status of PASSWORDLESS_CODE_SENT:
      # - "sent"      — the built-in mailer (delivery :built_in) enqueued the email.
      # - "failed"    — the built-in mailer was responsible but did not enqueue
      #                 it (its error was logged by the subscriber).
      # - "delegated" — delivery belongs to the host's PASSWORDLESS_CODE_GENERATED
      #                 subscriber (delivery :custom, or SMS); the engine cannot
      #                 know whether it sent anything.
      def delivery_status_for(challenge, generated_payload)
        return "delegated" unless StandardId::Events::Subscribers::PasswordlessDeliverySubscriber.handles?(generated_payload)

        challenge.built_in_delivered ? "sent" : "failed"
      end

      def emit_code_sent(username, delivery_status:)
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_SENT,
          identifier: username,
          channel: connection_type,
          realm: @realm,
          delivery_status: delivery_status
        )
      end
    end
  end
end
