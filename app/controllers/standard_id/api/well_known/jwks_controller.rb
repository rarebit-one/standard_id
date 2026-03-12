# frozen_string_literal: true

module StandardId
  module Api
    module WellKnown
      # Inherits from ActionController::API (not Api::BaseController) to avoid
      # content-type validation and no-store cache headers — JWKS is a public,
      # cacheable endpoint. Includes ControllerPolicy directly as a result.
      class JwksController < ActionController::API
        include StandardId::ControllerPolicy
        public_controller

        def show
          jwks = StandardId::JwtService.jwks

          if jwks.nil?
            render json: { error: "JWKS not available" }, status: :not_found
            return
          end

          response.headers["Cache-Control"] = "public, max-age=3600"
          render json: jwks
        end
      end
    end
  end
end
