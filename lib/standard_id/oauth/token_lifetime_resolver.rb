module StandardId
  module Oauth
    class TokenLifetimeResolver
      class << self
        DEFAULT_ACCESS_TOKEN_LIFETIME = 1.hour.to_i
        DEFAULT_REFRESH_TOKEN_LIFETIME = 30.days.to_i

        def access_token_for(flow_key)
          configured = lookup_token_lifetime(flow_key)
          seconds = positive_seconds(configured)

          (seconds.positive? ? seconds : default_access_token_lifetime).seconds
        end

        def refresh_token_lifetime
          seconds = positive_seconds(oauth_config.refresh_token_lifetime)
          seconds = DEFAULT_REFRESH_TOKEN_LIFETIME if seconds <= 0
          seconds.seconds
        end

        private

        def default_access_token_lifetime
          seconds = positive_seconds(oauth_config.default_token_lifetime)
          seconds = DEFAULT_ACCESS_TOKEN_LIFETIME if seconds <= 0
          seconds
        end

        def lookup_token_lifetime(flow_key)
          config = oauth_config
          return nil unless config.respond_to?(:token_lifetimes)

          lifetimes = config.token_lifetimes || {}
          lifetimes[flow_key.to_sym] || lifetimes[flow_key.to_s] if flow_key
        end

        def positive_seconds(value)
          case value
          when ActiveSupport::Duration
            value.to_i
          when Numeric, String
            value.to_i
          else
            0
          end
        end

        def oauth_config
          StandardId.config.oauth
        end
      end
    end
  end
end
