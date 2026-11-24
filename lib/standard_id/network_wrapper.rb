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
  # 5. Anything else (an open circuit that never ran the block, a breaker
  #    that turns the request's failure into its own error) becomes
  #    StandardId::ProviderUnavailableError, with the wrapper's error as
  #    `cause`. Callers therefore need no knowledge of the host's
  #    circuit-breaker library to map an outage.
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
    #   request (rule 5 above)
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

        raise StandardId::ProviderUnavailableError.new(provider: provider), cause: e
      end
    end
  end
end
