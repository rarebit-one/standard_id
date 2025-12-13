module StandardId
  module Events
    module Subscribers
      class LoggingSubscriber < Base
        subscribe_to_pattern(/\Astandard_id\./)

        LOG_LEVELS = {
          "authentication.attempt.started" => :debug,
          "authentication.attempt.succeeded" => :info,
          "authentication.attempt.failed" => :warn,
          "authentication.password.validated" => :debug,
          "authentication.password.failed" => :warn,
          "authentication.otp.validated" => :debug,
          "authentication.otp.failed" => :warn,
          "session.creating" => :debug,
          "session.created" => :info,
          "session.validating" => :debug,
          "session.validated" => :debug,
          "session.expired" => :info,
          "session.revoked" => :info,
          "session.refreshed" => :debug,
          "account.creating" => :debug,
          "account.created" => :info,
          "account.verified" => :info,
          "account.status_changed" => :warn,
          "account.activated" => :info,
          "account.deactivated" => :warn,
          "account.locked" => :warn,
          "account.unlocked" => :info,
          "identifier.created" => :debug,
          "identifier.verification.started" => :debug,
          "identifier.verification.succeeded" => :info,
          "identifier.verification.failed" => :warn,
          "identifier.linked" => :info,
          "oauth.authorization.requested" => :debug,
          "oauth.authorization.granted" => :info,
          "oauth.authorization.denied" => :info,
          "oauth.token.issuing" => :debug,
          "oauth.token.issued" => :info,
          "oauth.token.refreshed" => :debug,
          "oauth.code.consumed" => :debug,
          "passwordless.code.requested" => :debug,
          "passwordless.code.generated" => :debug,
          "passwordless.code.sent" => :info,
          "passwordless.code.verified" => :info,
          "passwordless.code.failed" => :warn,
          "passwordless.account.created" => :info,
          "social.auth.started" => :debug,
          "social.auth.callback_received" => :debug,
          "social.user_info.fetched" => :debug,
          "social.account.created" => :info,
          "social.account.linked" => :info,
          "social.auth.completed" => :info,
          "credential.password.created" => :info,
          "credential.password.reset_initiated" => :info,
          "credential.password.reset_completed" => :info,
          "credential.password.changed" => :info,
          "credential.client_secret.created" => :info,
          "credential.client_secret.rotated" => :warn
        }.freeze

        DEFAULT_LOG_LEVEL = :debug

        def call(event)
          return unless logging_enabled?

          log_level = LOG_LEVELS.fetch(event.short_name, DEFAULT_LOG_LEVEL)
          payload = build_payload(event, log_level)

          case log_level
          when :debug then StandardId.logger.debug(payload)
          when :info  then StandardId.logger.info(payload)
          when :warn  then StandardId.logger.warn(payload)
          when :error then StandardId.logger.error(payload)
          end
        end

        def handle_error(error, event)
          StandardId.logger.error({
            subject: "standard_id.logging_subscriber.error",
            event_type: event.short_name,
            error: error.message
          })
        end

        private

        def logging_enabled?
          config = StandardId.config
          return true unless config.respond_to?(:events)

          config.events.enable_logging
        end

        def build_payload(event, log_level)
          payload = {
            subject: "standard_id.#{event.short_name}",
            severity: log_level.to_s
          }

          payload[:duration] = event.duration_ms.round(2) if event.duration_ms

          if (account = event[:account])
            payload[:account_id] = account.respond_to?(:id) ? account.id : account
          elsif event[:account_id]
            payload[:account_id] = event[:account_id]
          end

          payload[:login] = event[:account_lookup] || event[:login] || event[:username] if event[:account_lookup] || event[:login] || event[:username]
          payload[:auth_method] = event[:auth_method] if event[:auth_method]
          payload[:grant_type] = event[:grant_type] if event[:grant_type]
          payload[:provider] = event[:provider] if event[:provider]
          payload[:session_type] = event[:session_type] if event[:session_type]
          payload[:ip_address] = event[:ip_address] if event[:ip_address]
          payload[:error_code] = event[:error_code] if event[:error_code]

          payload
        end
      end
    end
  end
end
