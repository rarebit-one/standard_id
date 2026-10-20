module StandardId
  module Oauth
    # RFC 9728 OAuth 2.0 Protected Resource Metadata, and the RFC 6750
    # `WWW-Authenticate` challenge that points clients at it.
    #
    # A host declares the resources it serves, keyed by the audience their
    # tokens carry:
    #
    #   c.oauth.protected_resources = {
    #     "mcp" => {
    #       path: "/mcp",                           # required: where the resource lives
    #       scopes_supported: %w[mcp mcp:read],     # default: audience_scopes["mcp"]
    #       authorization_servers: [...],           # default: [issuer || origin]
    #       bearer_methods_supported: %w[header],   # default
    #       resource_name: "Example MCP server"     # any other RFC 9728 member
    #     }
    #   }
    #
    # `path` may also be an absolute URL for a resource served from another
    # origin. Any member may be a callable taking one Hash
    # `{ origin:, audience:, issuer:, request: }`; a nil value removes the member.
    #
    # The document for a resource is served at
    # `<origin>/.well-known/oauth-protected-resource<path>` (RFC 9728 §3.1,
    # the path-inserted form that is the exact URL the challenge names) by
    # `standard_id_protected_resource_routes` in the host's routes file, and the
    # bare `/.well-known/oauth-protected-resource` serves the only configured
    # resource (or the one marked `root: true`) for clients probing the root
    # form. The engine also serves both under its own mount.
    #
    # Everything here is a pure function of config and an origin so it can be
    # used from the controller, from StandardId::ResourceServer, and from tests
    # without a request.
    module ProtectedResourceDocument
      WELL_KNOWN_PATH = "/.well-known/oauth-protected-resource".freeze
      RESERVED_KEYS = %w[path root].freeze

      module_function

      # @return [Hash{String => Hash}] configured resources, keys stringified
      def configured
        (StandardId.config.oauth.protected_resources || {}).to_h.each_with_object({}) do |(audience, entry), acc|
          acc[audience.to_s] = (entry || {}).to_h.transform_keys(&:to_s)
        end
      end

      # @return [Boolean] whether `audience` names a configured resource
      def configured?(audience)
        audience.present? && configured.key?(audience.to_s)
      end

      # The audience whose `path` is `path` (compared with the trailing slash
      # removed), or nil.
      def audience_for_path(path)
        wanted = normalize_path(path)
        return nil if wanted.empty?

        configured.each do |audience, entry|
          return audience if normalize_path(entry["path"]) == wanted
        end
        nil
      end

      # The audience served at the bare well-known URL: the only one configured,
      # else the one marked `root: true`, else nil.
      def default_audience
        all = configured
        return all.keys.first if all.size == 1

        all.each { |audience, entry| return audience if entry["root"] }
        nil
      end

      # Absolute URL of the resource (RFC 9728 `resource`).
      def resource_url(audience:, origin:)
        path = configured.dig(audience.to_s, "path")
        raise StandardId::ConfigurationError, "oauth.protected_resources[#{audience.inspect}] has no :path" if path.blank?
        return path.to_s.chomp("/") if absolute?(path)

        "#{origin.to_s.chomp('/')}#{normalize_path(path)}"
      end

      # Absolute URL of this resource's metadata document — the value the
      # `resource_metadata` challenge parameter carries.
      def metadata_url(audience:, origin:)
        path = configured.dig(audience.to_s, "path")
        suffix = absolute?(path) ? normalize_path(URI.parse(path.to_s).path) : normalize_path(path)
        "#{origin.to_s.chomp('/')}#{WELL_KNOWN_PATH}#{suffix}"
      end

      # @return [Hash] the RFC 9728 document for `audience`
      # @raise [StandardId::ConfigurationError] when the audience is not configured
      def build(audience:, origin:, request: nil)
        entry = configured[audience.to_s]
        raise StandardId::ConfigurationError, "oauth.protected_resources has no entry for #{audience.inspect}" if entry.nil?

        context = { origin: origin, audience: audience.to_s, issuer: StandardId::Oauth::DiscoveryResolver.issuer, request: request }
        doc = {
          resource: resource_url(audience: audience, origin: origin),
          authorization_servers: [StandardId::Oauth::DiscoveryResolver.issuer.presence || origin.to_s.chomp("/")],
          bearer_methods_supported: %w[header]
        }
        scopes = StandardId::Oauth::AudienceScopeResolver.scopes_for(audience: audience.to_s)
        doc[:scopes_supported] = scopes if scopes.any?

        entry.each do |key, value|
          next if RESERVED_KEYS.include?(key)

          resolved = value.respond_to?(:call) ? value.call(context) : value
          if resolved.nil?
            doc.delete(key.to_sym)
          else
            doc[key.to_sym] = resolved
          end
        end
        doc
      end

      # RFC 6750 §3 `WWW-Authenticate` value carrying the RFC 9728
      # `resource_metadata` pointer. `error` is one of the three RFC 6750 codes;
      # `scope` lists the scopes the resource needed (insufficient_scope).
      # Quoted values are limited to the RFC 6750 quoted-string charset; a
      # description that breaks it is dropped rather than emitted broken.
      def challenge(audience:, origin:, error: "invalid_token", error_description: nil, scope: nil)
        parts = [%(realm="#{audience}")]
        parts << %(error="#{error}") if error.present?
        parts << %(error_description="#{error_description}") if error_description.present? && quotable?(error_description)
        parts << %(scope="#{Array(scope).join(' ')}") if Array(scope).any?
        parts << %(resource_metadata="#{metadata_url(audience: audience, origin: origin)}")
        "Bearer #{parts.join(', ')}"
      end

      def quotable?(value)
        !value.to_s.match?(/["\\\r\n]/)
      end

      def absolute?(path)
        path.to_s.match?(%r{\Ahttps?://}i)
      end

      # "" or "/foo" — never "/" and never a trailing slash.
      def normalize_path(path)
        StandardId::Oauth::DiscoveryResolver.normalize_path(path)
      end
    end
  end
end
