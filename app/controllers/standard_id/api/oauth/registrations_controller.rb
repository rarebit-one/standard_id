module StandardId
  module Api
    module Oauth
      # RFC 7591 Dynamic Client Registration (POST /oauth/register) and RFC
      # 7592 client-configuration management (GET/PUT/DELETE
      # /oauth/register/:client_id).
      #
      # Everything is absent (404) unless
      # `StandardId.config.oauth.dynamic_registration_enabled` is true — an
      # open, unauthenticated registration endpoint is state-mutating attack
      # surface, so it is opt-in. The controller stays thin: it parses the JSON
      # client metadata and delegates the RFC 7591 -> ClientApplication mapping
      # (and the engine's security defaults and the host's pinned attributes)
      # to StandardId::Oauth::ClientRegistration.
      #
      # The management actions are authenticated by the per-client registration
      # access token issued at registration (returned once, stored as a digest),
      # presented as a bearer credential; a client manages only itself. They
      # exist once migration 20261020120000 has run.
      class RegistrationsController < BaseController
        public_controller

        # Throttle the open, unauthenticated endpoint by IP so an enabled
        # deployment can't be flooded with ClientApplication rows (or
        # management-token guesses).
        rate_limit to: StandardId.config.rate_limits.dynamic_registration_per_ip,
                   within: 1.hour,
                   name: "dynamic-registration-ip",
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        before_action :require_dynamic_registration_enabled!
        before_action :authenticate_registration_access!, only: %i[show update destroy]

        # POST /oauth/register
        def create
          result = StandardId::Oauth::ClientRegistration.call(client_metadata, request: request)
          render json: registration_response(result), status: :created
        end

        # GET /oauth/register/:client_id — RFC 7592 §2.1
        def show
          render json: client_information_response(@client)
        end

        # PUT /oauth/register/:client_id — RFC 7592 §2.2
        def update
          result = StandardId::Oauth::ClientRegistration.update(@client, client_metadata, request: request)
          render json: client_information_response(result.client)
        end

        # DELETE /oauth/register/:client_id — RFC 7592 §2.3
        def destroy
          StandardId::Oauth::ClientRegistration.deregister(@client)
          head :no_content
        end

        private

        # Return 404 (not 403) when the feature is off so the endpoint is
        # indistinguishable from one that does not exist.
        def require_dynamic_registration_enabled!
          head(:not_found) unless StandardId.config.oauth.dynamic_registration_enabled
        end

        # RFC 7592 §2: an unknown client, a client that was not dynamically
        # registered, a deregistered one, and a wrong or missing token are all
        # the same 401, so the endpoint does not reveal which client_ids exist.
        def authenticate_registration_access!
          return head(:not_found) unless StandardId::ClientApplication.registration_management_column?

          token = StandardId::BearerTokenExtraction.extract(request.headers["Authorization"])
          client = StandardId::ClientApplication.live.dynamically_registered.find_by(client_id: params[:client_id])

          if client&.authenticate_registration_access_token(token)
            @client = client
            return
          end

          challenge = token.present? ? %(Bearer error="invalid_token") : "Bearer"
          response.set_header("WWW-Authenticate", challenge)
          render json: {
            error: "invalid_token",
            error_description: "The registration access token does not authorize this client"
          }, status: :unauthorized
        end

        # Permit the full RFC 7591 client metadata document. We hand the raw
        # values to the service, which whitelists/maps them; the controller does
        # not need typed param coercion here.
        def client_metadata
          params.permit(
            :client_id,
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
        # client_secret_expires_at: 0 (never expires); plus, when management is
        # available, the RFC 7592 registration_client_uri and the one-time
        # registration_access_token.
        def registration_response(result)
          body = client_information_response(result.client)
          # Echo the registered value (RFC 7591 §3.2.1), not a value derived
          # from client_type — both client_secret_basic and client_secret_post
          # are accepted and both work at the token endpoint.
          body[:token_endpoint_auth_method] = result.token_endpoint_auth_method

          if result.client_secret
            body[:client_secret] = result.client_secret
            body[:client_secret_expires_at] = 0
          end
          body[:registration_access_token] = result.registration_access_token if result.registration_access_token
          body
        end

        # The stable client information document shared by create/show/update
        # (RFC 7591 §3.2.1, RFC 7592 §3). Never carries a secret or the
        # registration access token; those are returned once, at registration.
        def client_information_response(client)
          body = {
            client_id: client.client_id,
            client_id_issued_at: client.created_at.to_i,
            client_name: client.name,
            redirect_uris: client.redirect_uris_array,
            grant_types: client.grant_types_array,
            response_types: client.response_types_array,
            scope: client.scopes,
            token_endpoint_auth_method: client.token_endpoint_auth_method
          }
          body[:registration_client_uri] = registration_client_uri(client) if client.dynamically_registered?
          body
        end

        # Built from the request the way DiscoveryResolver builds endpoint URLs
        # for a document served inside the mount: script_name IS the mount path.
        def registration_client_uri(client)
          mount = StandardId::Oauth::DiscoveryResolver.normalize_path(request.script_name)
          "#{request.base_url}#{mount}/oauth/register/#{client.client_id}"
        end
      end
    end
  end
end
