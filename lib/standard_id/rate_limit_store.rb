module StandardId
  # A delegating cache store for rate limiting that lazily resolves the
  # backing store at request time. This allows the engine's rate_limit
  # declarations to work regardless of boot order, and respects the host
  # app's cache configuration.
  #
  # Resolution order:
  #   1. StandardId.config.cache_store (if it responds to :increment)
  #   2. Rails.cache
  class RateLimitStore
    def increment(name, amount = 1, **options)
      resolve_store.increment(name, amount, **options)
    end

    def read(name, **options)
      resolve_store.read(name, **options)
    end

    def write(name, value, **options)
      resolve_store.write(name, value, **options)
    end

    def delete(name, **options)
      resolve_store.delete(name, **options)
    end

    def clear(**options)
      resolve_store.clear(**options)
    end

    private

    def resolve_store
      configured = StandardId.config.cache_store
      if configured.respond_to?(:increment)
        configured
      else
        Rails.cache
      end
    end
  end
end
