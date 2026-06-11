module StandardId
  module Api
    module WellKnown
      # RFC 8414 OAuth 2.0 Authorization Server Metadata.
      #
      # Mirrors OpenidConfigurationController: a public endpoint, guarded on a
      # configured issuer, with a one-hour public cache. Both render the shared
      # StandardId::Oauth::DiscoveryDocument so the OIDC and OAuth metadata
      # documents cannot drift.
      #
      # MOUNT CAVEAT (RFC 8414): the ApiEngine is consumer-mounted at a sub-path
      # (e.g. `/auth/api`), so the gem can only serve this document at
      # `/auth/api/.well-known/oauth-authorization-server`. A strict RFC 8414
      # client that derives a root-anchored URL from a path-carrying issuer
      # (`<host>/.well-known/oauth-authorization-server/auth/api`) lands outside
      # any engine mount; hosts needing that form must add their own root route.
      class OauthAuthorizationServerController < ActionController::API
        include StandardId::ControllerPolicy
        public_controller

        def show
          issuer = StandardId.config.issuer

          unless issuer.present?
            render json: { error: "Issuer not configured" }, status: :not_found
            return
          end

          response.headers["Cache-Control"] = "public, max-age=3600"
          render json: StandardId::Oauth::DiscoveryDocument.build(
            issuer,
            registration_enabled: StandardId.config.oauth.dynamic_registration_enabled
          )
        end
      end
    end
  end
end
