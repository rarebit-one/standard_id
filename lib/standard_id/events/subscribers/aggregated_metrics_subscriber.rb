module StandardId
  module Events
    module Subscribers
      class AggregatedMetricsSubscriber < Base
        METRIC_MAPPINGS = {
          # Authentication metrics
          "authentication.attempt.succeeded" => { name: "auth.attempt", status: "success" },
          "authentication.attempt.failed" => { name: "auth.attempt", status: "failure" },
          "authentication.password.validated" => { name: "auth.password", status: "success" },
          "authentication.password.failed" => { name: "auth.password", status: "failure" },
          "authentication.otp.validated" => { name: "auth.otp", status: "success" },
          "authentication.otp.failed" => { name: "auth.otp", status: "failure" },
          # Session metrics
          "session.created" => { name: "session.created", status: "success" },
          "session.revoked" => { name: "session.revoked", status: "success" },
          "session.expired" => { name: "session.expired", status: "success" },
          # Account metrics
          "account.created" => { name: "account.created", status: "success" },
          "account.locked" => { name: "account.locked", status: "success" },
          "account.unlocked" => { name: "account.unlocked", status: "success" },
          # OAuth metrics
          "oauth.token.issued" => { name: "oauth.token.issued", status: "success" },
          "oauth.token.refreshed" => { name: "oauth.token.refreshed", status: "success" },
          "oauth.authorization.granted" => { name: "oauth.authorization", status: "success" },
          "oauth.authorization.denied" => { name: "oauth.authorization", status: "failure" },
          # Passwordless metrics
          "passwordless.code.verified" => { name: "passwordless.code", status: "success" },
          "passwordless.code.failed" => { name: "passwordless.code", status: "failure" },
          # Social metrics
          "social.auth.completed" => { name: "social.auth", status: "success" },
          "social.account.created" => { name: "social.account.created", status: "success" }
        }.freeze

        DEFAULT_BUCKET_SIZE = :five_minutes

        BUCKET_SIZES = %i[one_minute five_minutes fifteen_minutes thirty_minutes one_hour].freeze

        subscribe_to_pattern(/\Astandard_id\./)

        def call(event)
          return unless metrics_enabled?

          mapping = METRIC_MAPPINGS[event.short_name]
          return unless mapping

          dimensions = build_dimensions(event)
          time_bucket = calculate_time_bucket(event)
          duration = event.duration_ms || 0.0

          StandardId::Metric.increment(
            name: mapping[:name],
            status: mapping[:status],
            dimensions: dimensions,
            time_bucket: time_bucket,
            duration: duration
          )
        end

        def handle_error(error, event)
          StandardId.logger.error({
            subject: "standard_id.aggregated_metrics_subscriber.error",
            event_type: event.short_name,
            error: error.message,
            backtrace: error.backtrace&.first(5)
          })
        end

        private

        def metrics_enabled?
          config = StandardId.config
          return false unless config.respond_to?(:events)

          config.events.enable_metrics
        end

        def build_dimensions(event)
          dimensions = {}

          # Add auth method dimension for authentication events
          dimensions[:auth_method] = event[:auth_method] if event[:auth_method]

          # Add grant type for OAuth events
          dimensions[:grant_type] = event[:grant_type] if event[:grant_type]

          # Add provider for social events
          dimensions[:provider] = event[:provider] if event[:provider]

          # Add session type for session events
          dimensions[:session_type] = event[:session_type] if event[:session_type]

          # Add error code for failure events
          dimensions[:error_code] = event[:error_code] if event[:error_code]

          dimensions
        end

        def calculate_time_bucket(event)
          timestamp = parse_event_time(event)
          bucket_size = StandardId.config.events.metrics_bucket_size rescue DEFAULT_BUCKET_SIZE

          case bucket_size.to_sym
          when :one_minute
            timestamp.beginning_of_minute
          when :five_minutes
            round_to_minutes(timestamp, 5)
          when :fifteen_minutes
            round_to_minutes(timestamp, 15)
          when :thirty_minutes
            round_to_minutes(timestamp, 30)
          when :one_hour
            timestamp.beginning_of_hour
          else
            round_to_minutes(timestamp, 5) # default to 5 minutes
          end
        end

        def round_to_minutes(timestamp, minutes)
          Time.at((timestamp.to_i / (minutes * 60)) * (minutes * 60)).utc
        end

        def parse_event_time(event)
          return Time.current unless event.timestamp

          Time.iso8601(event.timestamp)
        rescue ArgumentError
          Time.current
        end
      end
    end
  end
end
