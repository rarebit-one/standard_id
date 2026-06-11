module StandardId
  module Api
    module Oauth
      # RFC 7591 Dynamic Client Registration endpoint (POST /oauth/register).
      #
      # The endpoint is fully absent (404) unless
      # `StandardId.config.oauth.dynamic_registration_enabled` is true — an open,
      # unauthenticated registration endpoint is state-mutating attack surface,
      # so it is opt-in. When enabled, the controller stays thin: it parses the
      # JSON client metadata and delegates the RFC 7591 -> ClientApplication
      # mapping (and the engine's security defaults) to
      # StandardId::Oauth::ClientRegistration.
      class RegistrationsController < BaseController
        public_controller

        # Throttle the open, unauthenticated registration endpoint by IP so an
        # enabled deployment can't be flooded with ClientApplication rows.
        rate_limit to: StandardId.config.rate_limits.dynamic_registration_per_ip,
                   within: 1.hour,
                   name: "dynamic-registration-ip",
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        before_action :require_dynamic_registration_enabled!

        # POST /oauth/register
        def create
          result = StandardId::Oauth::ClientRegistration.call(client_metadata)
          render json: registration_response(result), status: :created
        end

        private

        # Return 404 (not 403) when the feature is off so the endpoint is
        # indistinguishable from one that does not exist.
        def require_dynamic_registration_enabled!
          head(:not_found) unless StandardId.config.oauth.dynamic_registration_enabled
        end

        # Permit the full RFC 7591 client metadata document. We hand the raw
        # values to the service, which whitelists/maps them; the controller does
        # not need typed param coercion here.
        def client_metadata
          params.permit(
            :client_name,
            :scope,
            :token_endpoint_auth_method,
            redirect_uris: [],
            grant_types: [],
            response_types: []
          ).to_h.tap do |permitted|
            # `params.permit` drops scalars passed where an array was declared
            # (and vice versa); fall back to the raw value so the service can
            # accept either an array or a space-delimited string.
            %i[redirect_uris grant_types response_types].each do |key|
              permitted[key] = params[key] if permitted[key].blank? && params[key].present?
            end
          end
        end

        # RFC 7591 §3.2.1 success response. Echoes the registered metadata and,
        # for confidential clients, the one-time client_secret with
        # client_secret_expires_at: 0 (never expires).
        def registration_response(result)
          client = result.client

          body = {
            client_id: client.client_id,
            client_id_issued_at: client.created_at.to_i,
            client_name: client.name,
            redirect_uris: client.redirect_uris_array,
            grant_types: client.grant_types_array,
            response_types: client.response_types_array,
            scope: client.scopes,
            # Echo the registered value (RFC 7591 §3.2.1), not a value derived
            # from client_type — both client_secret_basic and client_secret_post
            # are accepted and both work at the token endpoint.
            token_endpoint_auth_method: result.token_endpoint_auth_method
          }

          if result.client_secret
            body[:client_secret] = result.client_secret
            body[:client_secret_expires_at] = 0
          end

          body
        end
      end
    end
  end
end
