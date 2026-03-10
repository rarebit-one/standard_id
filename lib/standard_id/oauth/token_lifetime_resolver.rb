module StandardId
  module Oauth
    class TokenLifetimeResolver
      DEFAULT_ACCESS_TOKEN_LIFETIME = 1.hour.to_i
      DEFAULT_REFRESH_TOKEN_LIFETIME = 30.days.to_i
      MAX_ACCESS_TOKEN_LIFETIME = 24.hours.to_i
      MAX_REFRESH_TOKEN_LIFETIME = 90.days.to_i

      class << self
        def access_token_for(flow_key)
          configured = lookup_token_lifetime(flow_key)
          clamp_seconds(positive_seconds(configured, default_access_token_lifetime), MAX_ACCESS_TOKEN_LIFETIME)
        end

        def refresh_token_lifetime
          clamp_seconds(positive_seconds(oauth_config.refresh_token_lifetime, DEFAULT_REFRESH_TOKEN_LIFETIME), MAX_REFRESH_TOKEN_LIFETIME)
        end

        private

        def default_access_token_lifetime
          positive_seconds(oauth_config.default_token_lifetime, DEFAULT_ACCESS_TOKEN_LIFETIME)
        end

        def lookup_token_lifetime(flow_key)
          config = oauth_config
          return nil unless config.respond_to?(:token_lifetimes)

          lifetimes = config.token_lifetimes || {}
          lifetimes[flow_key.to_sym] || lifetimes[flow_key.to_s] if flow_key
        end

        def positive_seconds(value, fallback_value)
          normalized_value = case value
          when ActiveSupport::Duration
            value.to_i
          when Numeric, String
            value.to_i
          else
            0
          end

          (normalized_value.positive? ? normalized_value : fallback_value).seconds
        end

        def clamp_seconds(duration, max)
          seconds = duration.to_i
          if seconds > max
            Rails.logger.warn { "[StandardId] Token lifetime #{seconds}s exceeds maximum #{max}s, clamping to #{max}s" }
            max.seconds
          else
            duration
          end
        end

        def oauth_config
          StandardId.config.oauth
        end
      end
    end
  end
end
