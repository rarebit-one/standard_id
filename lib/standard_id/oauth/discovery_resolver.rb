module StandardId
  module Oauth
    # Resolves the three request-dependent inputs of a discovery document:
    # the issuer, the endpoint base, and the overrides.
    #
    # Lives apart from DiscoveryDocument so the builder stays a pure function of
    # its arguments (and stays trivially testable without a request), while all
    # the "where am I actually mounted" reasoning is in one place.
    module DiscoveryResolver
      # Values of `discovery_endpoint_base` that mean "derive it from the
      # request". Compared as strings so `:request` and `"request"` both work —
      # this is set from an initializer and the symbol/string distinction is not
      # something a config file should have to get right.
      REQUEST_DERIVED = %w[request].freeze

      module_function

      # The issuer, verbatim from config. Never derived from the request, never
      # overridable: RFC 8414 §2 makes it a stable security identifier that
      # clients match byte-for-byte against their discovery URL and against the
      # `iss` claim of issued tokens.
      #
      # @return [String, nil]
      def issuer
        StandardId.config.issuer
      end

      # Base URL the advertised endpoints hang off, from
      # `config.oauth.discovery_endpoint_base`:
      #
      #   nil (default) — the issuer. EXACTLY the behaviour before this option
      #                   existed, so an upgrade changes no document. Correct
      #                   already for an app whose issuer carries the mount path
      #                   (`https://host/auth/api`); wrong, and the bug this
      #                   option exists for, when it does not.
      #   :request      — `request.base_url` + the detected mount path. This is
      #                   what an app mounting ApiEngine under a prefix wants.
      #   String        — used verbatim.
      #   callable      — called with `(request:)`. The escape hatch for a proxy
      #                   that rewrites `request.base_url`, and for an app that
      #                   mounts ApiEngine more than once (under host constraints,
      #                   say) where no single detected path is right.
      #
      # Request-derived is deliberately OPT-IN rather than the default. Making it
      # the default would silently rewrite the document of every app whose issuer
      # host differs from the host serving the request — which is exactly the
      # split-host setup a separate issuer exists to express.
      #
      # @param request [ActionDispatch::Request, nil]
      # @return [String, nil]
      def endpoint_base(request: nil)
        configured = StandardId.config.oauth.discovery_endpoint_base

        return issuer if configured.blank?

        if configured.respond_to?(:call)
          resolved = configured.call(request: request)
          return resolved.present? ? resolved.to_s.chomp("/") : issuer
        end

        return configured.to_s.chomp("/") unless REQUEST_DERIVED.include?(configured.to_s)
        return issuer if request.nil?

        "#{request.base_url}#{mount_path(request)}".chomp("/")
      end

      # The path ApiEngine is mounted at, as seen from this request.
      #
      # Two cases, and the difference is why this is not a config lookup:
      #
      #   * The document is served from INSIDE the engine mount (the gem's own
      #     `scope ".well-known"` routes). Rails sets SCRIPT_NAME to the mount
      #     prefix, so `request.script_name` IS the mount path, exactly, with no
      #     detection or guessing. This is the case that used to produce 404-ing
      #     endpoint URLs.
      #   * The document is served from a ROOT route drawn by
      #     `standard_id_well_known_routes` (RFC 8615 clients probe the origin
      #     root, which is outside any engine mount). There `script_name` is
      #     empty, so the helper stamps the mount path it was given into the
      #     route defaults and we read it back from `params`.
      #
      # @return [String] "" when neither is available, which resolves to the
      #   origin root — correct for an app that mounts ApiEngine at "/".
      def mount_path(request)
        from_defaults = request.params[MOUNT_PATH_PARAM].presence
        return normalize_path(from_defaults) if from_defaults

        normalize_path(request.script_name)
      end

      # Route default the routing helper uses to carry the mount path to a
      # root-served document. Named rather than positional so it cannot collide
      # with a host's own params.
      MOUNT_PATH_PARAM = :standard_id_mount_path

      # Resolve `config.oauth.discovery_metadata_overrides` for this request.
      #
      # Values may be static or callable. A callable receives one Hash argument
      # so members can be built from the request without each app re-deriving the
      # origin:
      #
      #   {
      #     # host-owned shim that injects the audience before handing off to the
      #     # engine's /authorize
      #     authorization_endpoint: ->(ctx) { "#{ctx[:origin]}/oauth/authorize" },
      #     # deliberately narrower than what the server can mint
      #     scopes_supported: %w[mcp mcp:read],
      #     # must mirror the host's DCR policy, or spec-following clients
      #     # register in a way that policy then rejects
      #     token_endpoint_auth_methods_supported: %w[none],
      #     # remove a member entirely
      #     grant_types_supported: nil
      #   }
      #
      # Context keys: `:origin` (scheme+host+port, no path), `:endpoint_base`,
      # `:issuer`, `:request`.
      #
      # @return [Hash] with callables evaluated
      def metadata_overrides(request: nil, endpoint_base: nil)
        configured = StandardId.config.oauth.discovery_metadata_overrides
        return {} if configured.blank?

        context = {
          origin: request&.base_url,
          endpoint_base: endpoint_base,
          issuer: issuer,
          request: request
        }

        configured.to_h.each_with_object({}) do |(key, value), acc|
          acc[key.to_sym] = value.respond_to?(:call) ? value.call(context) : value
        end
      end

      # Everything a well-known controller needs, in one call.
      #
      # @return [Hash] `{ issuer:, endpoint_base:, overrides: }`
      def resolve(request: nil)
        base = endpoint_base(request: request)

        {
          issuer: issuer,
          endpoint_base: base,
          overrides: metadata_overrides(request: request, endpoint_base: base)
        }
      end

      # "" or "/foo" — never "/" and never a trailing slash, so string
      # concatenation against an origin cannot produce a double slash.
      def normalize_path(path)
        normalized = path.to_s.chomp("/")
        return "" if normalized.empty?

        normalized.start_with?("/") ? normalized : "/#{normalized}"
      end
    end
  end
end
