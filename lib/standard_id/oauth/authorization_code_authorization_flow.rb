module StandardId
  module Oauth
    class AuthorizationCodeAuthorizationFlow < AuthorizationFlow
      expect_params :client_id
      # :audience is optional (RFC 6749 / RFC 8707 §2 treats `resource`/`audience`
      # as OPTIONAL at /authorize). Token-time validation in
      # TokenGrantFlow#validate_audience! already no-ops when audience is blank or
      # when no allowed_audiences are configured, so omitting it is safe and lets
      # standards-compliant clients (e.g. MCP) authorize without it.
      permit_params :audience, :scope, :redirect_uri, :state, :connection, :prompt, :organization, :invitation, :code_challenge, :code_challenge_method, :nonce

      private

      # Enforce per-client PKCE policy for authorization code flows. When the
      # client's require_pkce flag is enabled (the default, and always true
      # for public clients), the request must carry a code_challenge.
      def enforce_pkce_requirement!
        return unless @client&.require_pkce?
        return if params[:code_challenge].present?

        raise StandardId::InvalidRequestError, "code_challenge is required for this client"
      end

      def generate_authorization_response
        subflow_for(params).call
      end

      def subflow_for(flow_params)
        builders = {
          social: -> do
            Subflows::SocialLoginGrant.new(
              **common_subflow_params(flow_params),
              connection: flow_params[:connection],
              base_url: request.base_url
            )
          end,
          traditional: -> do
            Subflows::TraditionalCodeGrant.new(
              **common_subflow_params(flow_params),
              current_account: current_account
            )
          end
        }

        key = flow_params[:connection].present? ? :social : :traditional
        builders.fetch(key).call
      end

      def common_subflow_params(flow_params)
        {
          client_id: flow_params[:client_id],
          redirect_uri: redirect_uri,
          scope: scope,
          audience: audience,
          state: state,
          code_challenge: flow_params[:code_challenge],
          code_challenge_method: flow_params[:code_challenge_method],
          nonce: flow_params[:nonce]
        }
      end
    end
  end
end
