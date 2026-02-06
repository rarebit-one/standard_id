# frozen_string_literal: true

module StandardId
  module Api
    module WellKnown
      class JwksController < ActionController::API
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
