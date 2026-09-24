module StandardId
  module Events
    module Subscribers
      # Built-in OTP email delivery (`c.passwordless.delivery = :built_in`).
      #
      # Sign-in codes (realm "authentication") get PasswordlessMailer#otp_email;
      # every other realm — WebEngine email verification, Otp.issue step-up /
      # contact verification — gets #verification_email, so a verification code
      # never arrives as "your sign-in code". There is no built-in SMS delivery.
      #
      # On a successful enqueue it marks the code challenge
      # (CodeChallenge#built_in_delivered), which is how the strategy knows to
      # report PASSWORDLESS_CODE_SENT as "sent" rather than "failed".
      class PasswordlessDeliverySubscriber < Base
        subscribe_to StandardId::Events::PASSWORDLESS_CODE_GENERATED

        # Whether the built-in mailer is responsible for delivering this
        # PASSWORDLESS_CODE_GENERATED payload.
        #
        # @param payload [Hash] event payload (symbol or string keys)
        # @return [Boolean]
        def self.handles?(payload)
          payload = payload.with_indifferent_access
          # Per-call manual delivery (Otp.issue(delivery: :manual)) and
          # Otp.issue(delivery: :custom) leave delivery to the caller / host
          # subscriber, even when the engine mailer is the global default.
          return false if payload[:skip_sender]
          return false if payload[:delivery]&.to_sym == :custom

          StandardId.config.passwordless.delivery == :built_in && payload[:channel].to_s == "email"
        end

        def call(event)
          return unless self.class.handles?(event.payload)

          identifier = event[:identifier]
          challenge = event[:code_challenge]
          code = challenge&.code

          return if identifier.blank? || code.blank?

          StandardId::PasswordlessMailer.with(
            email: identifier,
            otp_code: code,
            realm: event[:realm],
            expires_in_minutes: expires_in_minutes(event[:expires_at])
          ).public_send(mailer_action(event[:realm])).deliver_later

          challenge.built_in_delivered = true if challenge.respond_to?(:built_in_delivered=)
        end

        def handle_error(error, event)
          StandardId.logger.error(
            "[StandardId::PasswordlessDelivery] Failed to deliver OTP email " \
            "for #{event[:identifier]}: #{error.message}"
          )
        end

        private

        def mailer_action(realm)
          realm.blank? || realm.to_s == StandardId::Passwordless::DEFAULT_REALM ? :otp_email : :verification_email
        end

        def expires_in_minutes(expires_at)
          return nil if expires_at.blank?

          [((Time.zone.parse(expires_at.to_s) - Time.current) / 60.0).ceil, 1].max
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
