module StandardId
  # Fixed-window counters on the configured rate-limit store, for limits the
  # engine enforces OUTSIDE a controller — where Rails' `rate_limit` macro
  # cannot reach. The first one is the OTP start path (Passwordless::BaseStrategy
  # #start!), which a host can drive from its own controllers, an operation or
  # a job without ever passing the engine's throttled actions.
  #
  # `STORE` is the same lazily-resolved RateLimitStore the engine's controllers
  # count on (RateLimitHandling::RATE_LIMIT_STORE is this object), so one
  # `c.cache_store` governs both, and a spec that stubs one stubs the other.
  module RateLimiter
    STORE = StandardId::RateLimitStore.new

    module_function

    # Count one hit against +key+ and raise once the window holds more than
    # +limit+. A non-positive limit disables the check. A store that cannot
    # count (`ActiveSupport::Cache::NullStore` answers nil) disables it too:
    # there is nothing to count against, and refusing everyone is worse than
    # counting nothing.
    #
    # @param key [String]
    # @param limit [Integer]
    # @param window [ActiveSupport::Duration, Integer] seconds
    # @raise [StandardId::RateLimitExceededError]
    def hit!(key, limit:, window:)
      return if limit.to_i <= 0

      count = STORE.increment(key, 1, expires_in: window)
      return if count.nil? || count.to_i <= limit.to_i

      raise StandardId::RateLimitExceededError.new(retry_after: window.to_i)
    end
  end
end
