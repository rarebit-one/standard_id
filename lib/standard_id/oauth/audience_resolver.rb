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
    #      "mcp" }); compared with the trailing slash removed. An unmapped
    #      resource resolves to nil, which the token endpoint's audience
    #      validation then judges like any absent audience.
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
          return answer.to_s if answer.present?
        end

        return requested.to_s if requested
        return from_resource(resource) if resource

        client_default(client)
      end

      def from_resource(resource)
        mapping = StandardId.config.oauth.resource_audiences || {}
        return nil if mapping.empty?

        key = normalize_resource(resource)
        mapping.each do |candidate, audience|
          return audience.to_s if normalize_resource(candidate) == key
        end
        nil
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
