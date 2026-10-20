module StandardId
  module Api
    module WellKnown
      # RFC 9728 OAuth 2.0 Protected Resource Metadata.
      #
      # `GET /.well-known/oauth-protected-resource/<resource path>` serves the
      # document for the resource configured at that path in
      # `config.oauth.protected_resources`; the bare form serves the default
      # (the only configured resource, or the one marked `root: true`). 404
      # when nothing matches, so a host with no protected resources exposes no
      # document. Public and cacheable, like the other discovery documents.
      #
      # Drawn at the origin root by `standard_id_protected_resource_routes`
      # (the challenge in StandardId::ResourceServer names that URL) and also
      # under the engine's own mount.
      class OauthProtectedResourceController < ActionController::API
        include StandardId::ControllerPolicy
        public_controller

        def show
          audience = resolve_audience

          unless audience
            render json: { error: "not_found", error_description: "No protected resource is configured at this path" },
              status: :not_found
            return
          end

          response.headers["Cache-Control"] = "public, max-age=3600"
          render json: StandardId::Oauth::ProtectedResourceDocument.build(
            audience: audience,
            origin: StandardId::Oauth::ProtectedResourceDocument.origin_for(audience, request: request),
            request: request
          )
        end

        private

        def resolve_audience
          path = params[:resource_path].presence
          return StandardId::Oauth::ProtectedResourceDocument.default_audience if path.nil?

          StandardId::Oauth::ProtectedResourceDocument.audience_for_path("/#{path}")
        end
      end
    end
  end
end
