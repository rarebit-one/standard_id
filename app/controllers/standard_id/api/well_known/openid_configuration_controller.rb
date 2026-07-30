module StandardId
  module Api
    module WellKnown
      class OpenidConfigurationController < ActionController::API
        include StandardId::ControllerPolicy
        public_controller

        def show
          resolved = StandardId::Oauth::DiscoveryResolver.resolve(request: request)

          unless resolved[:issuer].present?
            render json: { error: "Issuer not configured" }, status: :not_found
            return
          end

          response.headers["Cache-Control"] = "public, max-age=3600"
          render json: StandardId::Oauth::DiscoveryDocument.build(
            resolved[:issuer],
            endpoint_base: resolved[:endpoint_base],
            registration_enabled: StandardId.config.oauth.dynamic_registration_enabled,
            introspection_enabled: StandardId.config.oauth.introspection_enabled,
            overrides: resolved[:overrides]
          )
        end
      end
    end
  end
end
