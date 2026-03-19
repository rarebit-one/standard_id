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
          render json: discovery_document(issuer)
        end

        private

        def discovery_document(issuer)
          base = issuer.chomp("/")

          {
            issuer: issuer,
            authorization_endpoint: "#{base}/authorize",
            token_endpoint: "#{base}/oauth/token",
            revocation_endpoint: "#{base}/oauth/revoke",
            userinfo_endpoint: "#{base}/userinfo",
            jwks_uri: "#{base}/.well-known/jwks.json",
            response_types_supported: %w[code],
            grant_types_supported: %w[authorization_code refresh_token client_credentials password],
            subject_types_supported: %w[public],
            id_token_signing_alg_values_supported: [StandardId.config.oauth.signing_algorithm.to_s.upcase],
            token_endpoint_auth_methods_supported: %w[client_secret_basic client_secret_post]
          }.compact
        end
      end
    end
  end
end
