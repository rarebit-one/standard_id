module StandardId
  # Runs an outbound provider request through the host's
  # `StandardId.config.network_wrapper`, or directly when none is configured.
  # StandardId::HttpClient sends every request through here; a plugin with its
  # own HTTP code (one that may not use HttpClient's address guard) calls it
  # the same way, so the wrapper and its error contract cover it too:
  #
  #   StandardId::NetworkWrapper.run(provider: :example) { http.start { |h| h.request(req) } }
  #
  # Errors are told apart by where they were raised:
  #
  # - Raised by the block (the request: a timeout, a refused connection), and
  #   re-raised by the wrapper: they reach the caller as is, exactly as with
  #   no wrapper, so the caller's transport-error handling keeps working.
  # - Raised by the wrapper itself (an open circuit that never ran the block,
  #   a breaker that converts the request's error into its own, a failing
  #   tracer): replaced by StandardId::ProviderUnavailableError, with the
  #   wrapper's error as `cause`. Callers therefore need no knowledge of the
  #   host's circuit-breaker library to map an outage.
  # - A StandardId::OAuthError the wrapper raises deliberately (a
  #   ProviderUnavailableError from a nested call, or a refusal of the host's
  #   own) reaches the caller as is.
  module NetworkWrapper
    module_function

    # @param provider [Symbol, String, nil] the remote service (`:google`,
    #   `:apple`, ...), handed to the wrapper as `provider:`
    # @return whatever the block (through the wrapper) returns
    # @raise [StandardId::ProviderUnavailableError] the wrapper raised an
    #   error of its own
    def run(provider:, &block)
      wrapper = StandardId.config.network_wrapper
      return yield unless wrapper.respond_to?(:call)

      provider = provider&.to_sym
      arguments = StandardId::Utils::CallableParameterFilter.filter(wrapper, { provider: provider })
      # Every error the block raises, so a wrapper that retries can still be
      # told from one that raises its own.
      raised = []
      request = proc do |*args|
        block.call(*args)
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

        raise StandardId::ProviderUnavailableError.new(provider: provider), cause: e
      end
    end
  end
end
