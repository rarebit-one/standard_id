module StandardId
  module Oauth
    # Shared builder for the OIDC / OAuth 2.0 metadata documents served at:
    #   * /.well-known/openid-configuration   (OpenID Connect Discovery)
    #   * /.well-known/oauth-authorization-server (RFC 8414)
    #
    # Both well-known controllers render this single builder so the two
    # documents cannot drift.
    #
    # ## `issuer` and the endpoint base are two different things
    #
    # This used to derive every endpoint from the issuer
    # (`base = issuer.to_s.chomp("/")`), which is wrong for any app mounting
    # `ApiEngine` under a prefix its issuer does not carry: the document
    # advertised `<issuer>/oauth/token` while the endpoint actually lived at
    # `<origin>/api/oauth/token`. Every consuming app hand-rolled a replacement
    # controller because of it.
    #
    # The two are now separate, and must stay separate:
    #
    #   * `issuer` is a stable **security identifier** (RFC 8414 §2). Clients
    #     compare it byte-for-byte with the URL they used for discovery and with
    #     the `iss` claim of issued tokens. It is never derived from the request
    #     and can never be overridden — see .apply_overrides!.
    #   * `endpoint_base` is where the endpoints actually are. It defaults to the
    #     issuer, which preserves the previous behaviour exactly for apps whose
    #     issuer already carries the mount path.
    #
    # ## Overrides
    #
    # Some members are not derivable at all — a host-owned authorization shim
    # that injects an audience, a scope list deliberately narrower than what the
    # server can mint, an auth-method list that must mirror the host's dynamic
    # registration policy. `overrides` covers those; see
    # StandardId::Oauth::DiscoveryResolver for the config surface.
    module DiscoveryDocument
      module_function

      # @param issuer [String] the configured issuer, emitted verbatim
      # @param endpoint_base [String, nil] base URL for the endpoints. Defaults
      #   to `issuer` — the previous behaviour — so existing callers are
      #   unaffected.
      # @param registration_enabled [Boolean] when true, advertises the RFC 7591
      #   dynamic client registration endpoint. The well-known controllers pass
      #   `StandardId.config.oauth.dynamic_registration_enabled` here, so the
      #   `registration_endpoint` is emitted only when DCR is turned on. Defaults
      #   to false so callers (and tests) that omit it get no registration_endpoint.
      # @param introspection_enabled [Boolean] when true, advertises the RFC 7662
      #   introspection endpoint. The well-known controllers pass
      #   `StandardId.config.oauth.introspection_enabled`, so it is advertised only
      #   when the endpoint actually exists (the controller 404s when off).
      #   Defaults to false, matching registration_enabled.
      # @param overrides [Hash] members to replace, add, or (with a nil value)
      #   remove. Already resolved — callables are evaluated by the caller.
      # @return [Hash]
      def build(issuer, endpoint_base: nil, registration_enabled: false,
        introspection_enabled: false, overrides: {})
        base = (endpoint_base.presence || issuer).to_s.chomp("/")

        doc = {
          issuer: issuer,
          authorization_endpoint: "#{base}/authorize",
          token_endpoint: "#{base}/oauth/token",
          revocation_endpoint: "#{base}/oauth/revoke",
          userinfo_endpoint: "#{base}/userinfo",
          response_types_supported: %w[code],
          grant_types_supported: %w[authorization_code refresh_token client_credentials],
          subject_types_supported: %w[public],
          id_token_signing_alg_values_supported: [StandardId.config.oauth.signing_algorithm.to_s.upcase],
          # "none" advertises public-client support (PKCE-only token exchange,
          # no client_secret) per RFC 8414 — required by native/SPA/MCP clients.
          token_endpoint_auth_methods_supported: %w[client_secret_basic client_secret_post none],
          # PKCE is always enforced (require_pkce defaults true and cannot be
          # disabled for public clients), so advertise the supported method.
          code_challenge_methods_supported: %w[S256]
        }

        # Only advertise jwks_uri when signing is asymmetric. With symmetric
        # (HS256/384/512) signing there are no public keys to publish, so the
        # jwks endpoint deliberately returns 404 — advertising it would point
        # clients at a dead URL. HS-signed tokens are verified with the shared
        # secret, not JWKS. (RFC 8414 makes jwks_uri optional; an OIDC client
        # using HS256 id_tokens verifies them with the client_secret.)
        doc[:jwks_uri] = "#{base}/.well-known/jwks.json" if StandardId::JwtService.asymmetric?

        doc[:registration_endpoint] = "#{base}/oauth/register" if registration_enabled
        doc[:introspection_endpoint] = "#{base}/oauth/introspect" if introspection_enabled

        apply_overrides!(doc, overrides)
      end

      # Merge resolved overrides into the document.
      #
      # A `nil` value REMOVES the member rather than emitting `null`. Real apps
      # need that — one omits `scopes_supported` entirely — and a `null` would be
      # worse than either alternative, since RFC 8414 members are typed.
      #
      # `issuer` is REFUSED rather than silently dropped. It is a security
      # identifier clients match byte-for-byte against both their discovery URL
      # and the `iss` claim; letting a metadata override diverge it from what the
      # token service actually stamps would produce a document that validates
      # against nothing, and the failure would surface a long way from here.
      def apply_overrides!(doc, overrides)
        return doc if overrides.blank?

        overrides = overrides.symbolize_keys
        if overrides.key?(:issuer)
          raise StandardId::ConfigurationError,
            "discovery_metadata_overrides cannot set `issuer`. The issuer is a stable " \
            "security identifier (RFC 8414 §2): clients compare it byte-for-byte with " \
            "the URL they used for discovery and with the `iss` claim of issued tokens, " \
            "so it must stay exactly StandardId.config.issuer. To move where the " \
            "ENDPOINTS live, set config.oauth.discovery_endpoint_base instead."
        end

        overrides.each do |key, value|
          value.nil? ? doc.delete(key) : doc[key] = value
        end

        doc
      end
    end
  end
end
