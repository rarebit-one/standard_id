module StandardId
  module Oauth
    # Which audience an /authorize request is for — decided server-side, from
    # what the request and the registered client say, rather than trusted from
    # a client-supplied `audience` alone.
    #
    # Resolution order:
    #   1. `config.oauth.audience_resolver`, when set: a callable taking any
    #      subset of `client:`, `audience:` (the raw param), `resource:` (the
    #      RFC 8707 param) and `request:`. A non-nil answer is final; nil
    #      falls through to the defaults below.
    #   2. The `audience` parameter, when present (what hosts' shims inject
    #      today, so nothing changes for them).
    #   3. The `resource` parameter (RFC 8707), mapped through
    #      `config.oauth.resource_audiences` ({ "https://app.example/mcp" =>
    #      "mcp" }); compared with the trailing slash removed. With no mapping
    #      configured the parameter is ignored (MCP clients send it on every
    #      request, and a host relying on the client default below must still
    #      get that default). With a mapping, an unmapped resource is refused
    #      with `invalid_target` (RFC 8707 §2), never silently issued without
    #      an audience.
    #   4. The client's registered default, `metadata["audience"]` — the
    #      convention every dynamic-registration operation in the estate
    #      stamps, and the reason each app carried an authorize shim.
    #
    # Nil when none of these apply: audience stays optional at /authorize.
    module AudienceResolver
      module_function

      def resolve(client:, params:, request: nil)
        requested = params[:audience].presence
        resource = params[:resource].presence

        custom = StandardId.config.oauth.audience_resolver
        if custom.respond_to?(:call)
          context = { client: client, audience: requested, resource: resource, request: request }
          answer = custom.call(**StandardId::Utils::CallableParameterFilter.filter(custom, context))
          return coerce_hook_answer(answer) unless answer.nil?
        end

        return requested.to_s if requested
        return from_resource(resource) if resource && resource_mapping.any?

        client_default(client)
      end

      # @raise [StandardId::InvalidTargetError] when a mapping is configured
      #   and this resource is not in it
      def from_resource(resource)
        key = normalize_resource(resource)
        resource_mapping.each do |candidate, audience|
          return audience.to_s if normalize_resource(candidate) == key
        end

        raise StandardId::InvalidTargetError, "The resource parameter is not a resource this server issues tokens for"
      end

      def resource_mapping
        StandardId.config.oauth.resource_audiences || {}
      end

      # The hook's contract is "nil falls through, anything else is the
      # audience". A String or Symbol is it; a blank string is treated as "no
      # audience" (the hook decided, and decided none). Anything else is a
      # programming error worth failing loudly on rather than stringifying.
      def coerce_hook_answer(answer)
        case answer
        when String, Symbol then answer.to_s.presence
        else
          raise StandardId::ConfigurationError,
            "StandardId config: `oauth.audience_resolver` must return a String, Symbol or nil, got #{answer.class}"
        end
      end

      def client_default(client)
        return nil if client.nil?

        metadata = client.respond_to?(:metadata) ? client.metadata : nil
        value = metadata.is_a?(Hash) ? (metadata["audience"] || metadata[:audience]) : nil
        value.presence&.to_s
      end

      def normalize_resource(value)
        value.to_s.strip.delete_suffix("/")
      end
    end
  end
end
