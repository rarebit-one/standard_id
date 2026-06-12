module StandardId
  module Oauth
    # Shared builder for the OIDC / OAuth 2.0 metadata documents served at:
    #   * /.well-known/openid-configuration   (OpenID Connect Discovery)
    #   * /.well-known/oauth-authorization-server (RFC 8414)
    #
    # Both well-known controllers render this single builder so the two
    # documents cannot drift. Endpoint URLs are derived from the configured
    # issuer.
    #
    # NOTE on mounting (RFC 8414 caveat): the ApiEngine is consumer-mounted at
    # a sub-path (e.g. `/auth/api`), so the gem can only serve
    # `/auth/api/.well-known/oauth-authorization-server`. A strict RFC 8414
    # client that derives a *root-anchored* metadata URL from a path-carrying
    # issuer would probe `<host>/.well-known/oauth-authorization-server/auth/api`,
    # which falls outside any engine mount. Hosts that need the root-anchored
    # form must add their own root route — the gem cannot.
    module DiscoveryDocument
      module_function

      # @param issuer [String] the configured issuer (e.g. "https://auth.example.com")
      # @param registration_enabled [Boolean] when true, advertises the RFC 7591
      #   dynamic client registration endpoint. The well-known controllers pass
      #   `StandardId.config.oauth.dynamic_registration_enabled` here, so the
      #   `registration_endpoint` is emitted only when DCR is turned on. Defaults
      #   to false so callers (and tests) that omit it get no registration_endpoint.
      # @return [Hash]
      def build(issuer, registration_enabled: false)
        base = issuer.to_s.chomp("/")

        doc = {
          issuer: issuer,
          authorization_endpoint: "#{base}/authorize",
          token_endpoint: "#{base}/oauth/token",
          revocation_endpoint: "#{base}/oauth/revoke",
          userinfo_endpoint: "#{base}/userinfo",
          jwks_uri: "#{base}/.well-known/jwks.json",
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

        doc[:registration_endpoint] = "#{base}/oauth/register" if registration_enabled

        doc
      end
    end
  end
end
