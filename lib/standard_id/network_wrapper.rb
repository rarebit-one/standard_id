module StandardId
  # Runs an outbound provider request through the host's
  # `StandardId.config.network_wrapper`, or directly when none is configured.
  # StandardId::HttpClient sends every request through here; a plugin with its
  # own HTTP code (one that may not use HttpClient's address guard) calls it
  # the same way, so the wrapper and its error contract cover it too:
  #
  #   StandardId::NetworkWrapper.run(provider: :example) { http.start { |h| h.request(req) } }
  #
  # With no wrapper, the block runs directly and nothing is rescued. With one,
  # an error that leaves the wrapper is handled by the first rule that matches:
  #
  # 1. A StandardId::OAuthError (a ProviderUnavailableError from a nested
  #    call, or a refusal of the host's own) reaches the caller as is.
  # 2. An error the block raised (the request: a timeout, a refused
  #    connection), re-raised by the wrapper as the same object, reaches the
  #    caller as is, exactly as with no wrapper.
  # 3. If the most recent call of the block returned normally, the request
  #    went through (an authorization code may be spent), so the wrapper's
  #    error (a failing tracer, say) reaches the caller as is: telling the
  #    user to retry would be wrong. With a retrying wrapper, only the last
  #    call counts.
  # 4. A programming error in the wrapper (PROGRAMMING_ERRORS: a typo, an
  #    unloaded constant, a wrong call) reaches the caller as is, so it is
  #    reported as the bug it is, not shown as an outage.
  # 5. An error the host listed in `config.network_wrapper_passthrough_errors`
  #    (a misconfiguration of its own, such as a circuit that was never
  #    registered) reaches the caller as is, for the same reason.
  # 6. Anything else (an open circuit that never ran the block, a breaker
  #    that turns the request's failure into its own error) becomes
  #    StandardId::ProviderUnavailableError, with the wrapper's error as
  #    `cause`. Callers therefore need no knowledge of the host's
  #    circuit-breaker library to map an outage. When the wrapper's error
  #    says how long to wait (see .retry_after_from), the
  #    ProviderUnavailableError carries it as `retry_after`, which the API
  #    sends as a Retry-After header.
  #
  # Non-StandardError exceptions (Interrupt, ...) are never touched.
  module NetworkWrapper
    # Errors a host wrapper raises because its own code is wrong, never
    # because the provider is down. NameError covers NoMethodError.
    PROGRAMMING_ERRORS = [NameError, TypeError, ArgumentError].freeze

    module_function

    # @param provider [Symbol, String, nil] the remote service (`:google`,
    #   `:apple`, ...), handed to the wrapper as `provider:`
    # @return whatever the block (through the wrapper) returns
    # @raise [StandardId::ProviderUnavailableError] the wrapper refused the
    #   request (rule 6 above)
    def run(provider:, &block)
      wrapper = StandardId.config.network_wrapper
      return yield unless wrapper.respond_to?(:call)

      provider = provider&.to_sym
      arguments = StandardId::Utils::CallableParameterFilter.filter(wrapper, { provider: provider })
      # Every error the block raised (rule 2), and whether its latest call
      # returned normally (rule 3).
      raised = []
      returned = false
      request = proc do |*args|
        returned = false
        result = block.call(*args)
        returned = true
        result
      rescue StandardError => e
        raised << e
        raise
      end

      begin
        wrapper.call(**arguments, &request)
      rescue StandardId::OAuthError
        raise
      rescue StandardError => e
        raise if raised.any? { |error| error.equal?(e) }
        raise if returned
        raise if PROGRAMMING_ERRORS.any? { |klass| e.is_a?(klass) }
        raise if passthrough_errors.any? { |klass| e.is_a?(klass) }

        raise StandardId::ProviderUnavailableError.new(provider: provider, retry_after: retry_after_from(e)), cause: e
      end
    end

    # The classes in `config.network_wrapper_passthrough_errors`. A String
    # names a class that may not be loaded (it may come from a gem the host
    # has not required), so it is resolved on each call and skipped while it
    # names nothing.
    #
    # @return [Array<Module>]
    def passthrough_errors
      Array(StandardId.config.network_wrapper_passthrough_errors).filter_map do |entry|
        klass = entry.is_a?(Module) ? entry : entry.to_s.safe_constantize
        klass if klass.is_a?(Module)
      end
    end

    # How long, in whole seconds, the wrapper's error says to wait before
    # retrying, or nil when it doesn't say. Duck-typed, so no breaker library
    # is assumed: a `retry_after` that is a Time (when to retry) or a Numeric
    # (seconds) decides; without one, `cool_off_time` in seconds. Stoplight's
    # RedLight has both, with `retry_after` nil while a light is locked red.
    #
    # @param error [Exception] the wrapper's error
    # @return [Integer, nil] a positive number of seconds, or nil
    def retry_after_from(error)
      value = error.retry_after if error.respond_to?(:retry_after)
      value -= Time.now if value.is_a?(Time)
      value = error.cool_off_time if !value.is_a?(Numeric) && error.respond_to?(:cool_off_time)

      value.ceil if value.is_a?(Numeric) && value.positive?
    rescue StandardError
      # Only a hint for a header: a host error whose accessor misbehaves must
      # not replace the ProviderUnavailableError being raised.
      nil
    end
  end
end
