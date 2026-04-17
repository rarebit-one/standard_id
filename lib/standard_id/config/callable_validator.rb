module StandardId
  module Config
    # Validates that callables configured on StandardId.config have signatures
    # the engine can actually invoke. Runs once during Rails boot from the
    # engine's `config.after_initialize` block. On mismatch, raises
    # ConfigurationError with a message naming the offending field.
    #
    # What "matches" means:
    # - Positional callables: a configured proc/lambda/method ref must accept
    #   the exact number of positional arguments the engine will pass. A
    #   lambda with all-optional/splat params (arity < 0) is accepted so long
    #   as it can plausibly be called with that many positional args.
    # - Keyword callables (custom_claims, claim_resolvers): the callable is
    #   invoked via CallableParameterFilter which slices the context hash to
    #   the callable's declared keyword parameters. So keyword callables pass
    #   validation as long as every declared keyword name is one the engine
    #   actually provides — otherwise the call would `ArgumentError` at
    #   runtime.
    #
    # Scope: only validates top-level StandardId.config fields plus the hash
    # entries under `oauth.claim_resolvers`. Does NOT modify the StandardConfig
    # DSL (the gem's schema doesn't need to know about this).
    module CallableValidator
      # Each entry: field_path => { signature: "(a, b, c)", arity: Integer, kind: :positional | :keyword, keywords: [..] }
      # Field path is the method chain on StandardId.config, e.g. "after_sign_in"
      # or "oauth.custom_claims".
      CALLABLE_FIELDS = {
        "profile_resolver"        => { signature: "(account, profile_type)",            arity: 2, kind: :positional },
        "sentry_context"          => { signature: "(account, session)",                 arity: 2, kind: :positional },
        "after_account_created"   => { signature: "(account, request, context)",        arity: 3, kind: :positional },
        "before_sign_in"          => { signature: "(account, request, context)",        arity: 3, kind: :positional },
        "after_sign_in"           => { signature: "(account, request, context)",        arity: 3, kind: :positional },
        "passwordless.username_validator" => { signature: "(username, connection_type)", arity: 2, kind: :positional },
        "passwordless.account_factory"    => {
          signature: "(identifier:, params:, request:)",
          kind: :keyword,
          keywords: %i[identifier params request]
        },
        "oauth.custom_claims" => {
          signature: "(account:, client:, request:, audience:)",
          kind: :keyword,
          keywords: %i[account client request audience]
        }
      }.freeze

      # Keys available to claim_resolvers callables at invocation time.
      CLAIM_RESOLVER_KEYWORDS = %i[client account request audience].freeze

      class << self
        def validate!(config = StandardId.config)
          CALLABLE_FIELDS.each do |path, spec|
            callable = fetch(config, path)
            next if callable.nil?
            next unless callable.respond_to?(:call)
            validate_callable!(path, callable, spec)
          end

          validate_claim_resolvers!(config)
        end

        private

        def fetch(config, path)
          path.split(".").inject(config) do |receiver, segment|
            return nil if receiver.nil?
            receiver.public_send(segment)
          end
        rescue NoMethodError
          nil
        end

        def validate_callable!(path, callable, spec)
          case spec[:kind]
          when :positional then validate_positional!(path, callable, spec)
          when :keyword    then validate_keyword!(path, callable, spec[:keywords], spec[:signature])
          end
        end

        def validate_positional!(path, callable, spec)
          expected = spec[:arity]
          actual = callable.arity

          # Lambdas with all-required positional args have a positive arity;
          # must match exactly. Otherwise (optional/splat/kwargs) arity is
          # negative — accept it since the callable can absorb the call.
          return if actual == expected
          return if actual < 0

          raise StandardId::ConfigurationError,
            "StandardId config: `#{path}` expects signature #{spec[:signature]} " \
            "(arity #{expected}), got arity #{actual}"
        end

        def validate_keyword!(path, callable, allowed_keywords, signature)
          params = extract_parameters(callable)
          return if params.nil?
          # If the callable takes a double-splat, it accepts anything — fine.
          return if params.any? { |type, _| type == :keyrest }

          declared = params.select { |type, _| %i[key keyreq keyopt].include?(type) }.map { |_, name| name }
          unknown = declared - allowed_keywords
          return if unknown.empty?

          raise StandardId::ConfigurationError,
            "StandardId config: `#{path}` declares unknown keyword argument(s) " \
            "#{unknown.inspect}. Expected signature #{signature} " \
            "(allowed keywords: #{allowed_keywords.inspect})."
        end

        def validate_claim_resolvers!(config)
          resolvers = config.oauth.claim_resolvers
          return if resolvers.nil? || resolvers.empty?

          resolvers.each do |claim_key, resolver|
            next unless resolver.respond_to?(:call)
            spec_signature = "(#{CLAIM_RESOLVER_KEYWORDS.map { |k| "#{k}:" }.join(', ')})"
            validate_keyword!(
              "oauth.claim_resolvers[#{claim_key.inspect}]",
              resolver,
              CLAIM_RESOLVER_KEYWORDS,
              spec_signature
            )
          end
        end

        def extract_parameters(callable)
          if callable.respond_to?(:parameters)
            callable.parameters
          elsif callable.respond_to?(:method)
            callable.method(:call).parameters
          end
        end
      end
    end
  end
end
