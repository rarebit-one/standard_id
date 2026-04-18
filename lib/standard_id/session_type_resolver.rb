module StandardId
  # Resolves which Session subclass to create for a given auth flow.
  #
  # Delegates to `StandardId.config.session.session_type_resolver` when set.
  # Falls back to `DEFAULT` which mirrors the gem's historical behaviour.
  #
  # Return values from a configured resolver may be:
  #   - A Session subclass (BrowserSession, DeviceSession, ServiceSession)
  #   - A symbol (:browser, :device, :service) — mapped to the matching class
  #   - `nil` / `false` — meaning "do not create a session for this flow".
  #     This is only honoured by callsites that support it (see `resolve!`
  #     vs `resolve_optional!`).
  module SessionTypeResolver
    SYMBOL_MAP = {
      browser: "StandardId::BrowserSession",
      device: "StandardId::DeviceSession",
      service: "StandardId::ServiceSession"
    }.freeze

    # Default resolver — returns the class the gem would historically choose
    # for each flow. Defined as a lambda (not a Proc) so missing kwargs raise.
    DEFAULT = ->(request:, account:, flow:) {
      case flow
      when :web_sign_in then :browser
      when :api_device_auth then :device
      when :api_service_auth then :service
      when :oauth_token_issued then nil # gem historically persists no session here
      else
        # Unknown flow — raise loudly rather than silently defaulting to :browser.
        # A misspelled flow symbol or a newly-added flow that forgot to register
        # here would otherwise mint a BrowserSession with no indication anything
        # was wrong. Host apps that add custom flows are expected to supply
        # their own resolver.
        raise StandardId::ConfigurationError,
          "session_type_resolver: unknown flow #{flow.inspect}. " \
          "Configure StandardId.config.session.session_type_resolver to handle it, " \
          "or use one of: :web_sign_in, :api_device_auth, :api_service_auth, :oauth_token_issued."
      end
    }

    class << self
      # Resolve the session class for a flow where session creation is
      # mandatory (web sign-in, API device/service auth). Returns a Class.
      # Raises ConfigurationError on nil / unknown returns.
      def resolve!(request:, account:, flow:)
        klass = coerce(call_resolver(request: request, account: account, flow: flow), flow: flow)
        if klass.nil?
          raise StandardId::ConfigurationError,
            "session_type_resolver returned nil for flow #{flow.inspect}; " \
            "this flow requires a session class (one of :browser, :device, :service)"
        end
        klass
      end

      # Resolve the session class for a flow where session creation is
      # optional (oauth_token_issued). Returns a Class or nil.
      # Raises ConfigurationError on invalid non-nil returns.
      def resolve_optional(request:, account:, flow:)
        coerce(call_resolver(request: request, account: account, flow: flow), flow: flow)
      end

      private

      def call_resolver(request:, account:, flow:)
        resolver = StandardId.config.session.session_type_resolver || DEFAULT
        unless resolver.respond_to?(:call)
          raise StandardId::ConfigurationError,
            "StandardId.config.session.session_type_resolver must be callable " \
            "(got #{resolver.class})"
        end

        resolver.call(request: request, account: account, flow: flow)
      end

      def coerce(value, flow:)
        return nil if value.nil? || value == false

        case value
        when Symbol
          class_name = SYMBOL_MAP[value]
          unless class_name
            raise StandardId::ConfigurationError,
              "session_type_resolver returned unknown symbol #{value.inspect} " \
              "for flow #{flow.inspect}; expected one of #{SYMBOL_MAP.keys.inspect}"
          end
          class_name.constantize
        when Class
          unless SYMBOL_MAP.values.include?(value.name)
            raise StandardId::ConfigurationError,
              "session_type_resolver returned #{value.name} for flow #{flow.inspect}; " \
              "expected one of #{SYMBOL_MAP.values.inspect}"
          end
          value
        else
          raise StandardId::ConfigurationError,
            "session_type_resolver returned #{value.inspect} (#{value.class}) " \
            "for flow #{flow.inspect}; expected a Session subclass, symbol, or nil"
        end
      end
    end
  end
end
