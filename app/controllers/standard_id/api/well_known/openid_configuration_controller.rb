module StandardId
  module Api
    module WellKnown
      class OpenidConfigurationController < ActionController::API
        include StandardId::ControllerPolicy
        public_controller

        def show
          issuer = StandardId.config.issuer

          unless issuer.present?
            render json: { error: "Issuer not configured" }, status: :not_found
            return
          end

          response.headers["Cache-Control"] = "public, max-age=3600"
          render json: StandardId::Oauth::DiscoveryDocument.build(issuer)
        end
      end
    end
  end
end
