module StandardId
  module Events
    module Subscribers
      class AuditLogSubscriber < Base
        DEFAULT_AUDIT_EVENTS = [
          # Authentication events
          "authentication.attempt.succeeded",
          "authentication.attempt.failed",
          "authentication.password.failed",
          "authentication.otp.failed",
          # Session events
          "session.created",
          "session.revoked",
          "session.expired",
          # Account events
          "account.created",
          "account.verified",
          "account.status_changed",
          "account.activated",
          "account.deactivated",
          "account.locked",
          "account.unlocked",
          # Identifier events
          "identifier.verification.failed",
          # OAuth events
          "oauth.authorization.granted",
          "oauth.authorization.denied",
          "oauth.token.issued",
          "oauth.token.refreshed",
          # Passwordless events
          "passwordless.code.failed",
          "passwordless.account.created",
          # Credential events
          "credential.password.created",
          "credential.password.reset_initiated",
          "credential.password.reset_completed",
          "credential.password.changed",
          "credential.client_secret.created",
          "credential.client_secret.rotated",
          "credential.client_secret.revoked",
          # Social events
          "social.account.created",
          "social.account.linked"
        ].freeze

        class << self
          def audit_events
            StandardId.config.events.audit_events.presence || DEFAULT_AUDIT_EVENTS
          end

          def attach
            subscribe_to(*audit_events.map { |e| "standard_id.#{e}" })
            super
          end
        end

        def call(event)
          StandardId::AuditLog.create!(
            event_type: event.short_name,
            request_id: event[:request_id],
            actor: extract_actor(event),
            target: extract_target(event),
            ip_address: event[:ip_address],
            metadata: build_metadata(event),
            occurred_at: parse_timestamp(event.timestamp)
          )
        end

        def handle_error(error, event)
          StandardId.logger.error({
            subject: "standard_id.audit_log_subscriber.error",
            event_type: event.short_name,
            error: error.message,
            backtrace: error.backtrace
          })
        end

        private

        def extract_actor(event)
          # For admin actions, prefer current_account (who performed the action)
          # over account (the target of the action)
          event[:actor] || event[:current_account] || event[:account] || event[:client_application]
        end

        def extract_target(event)
          # Target is the entity being acted upon (different from actor)
          # Only set if current_account exists and target is different from actor
          return nil unless event[:current_account]

          target = event[:account] || event[:client_application]
          return nil if target.nil? || target == event[:current_account]

          target
        end

        EXCLUDED_METADATA_KEYS = %i[
          event_type event_id timestamp request_id ip_address
          actor account current_account client_application target
        ].freeze

        def build_metadata(event)
          metadata = event.payload.except(*EXCLUDED_METADATA_KEYS)
          metadata[:duration_ms] = event.duration_ms&.round(2) if event.duration_ms
          metadata.compact
        end

        def parse_timestamp(timestamp)
          return Time.current unless timestamp

          Time.iso8601(timestamp)
        rescue ArgumentError
          Time.current
        end
      end
    end
  end
end
