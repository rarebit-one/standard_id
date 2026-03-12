module StandardId
  module Oauth
    class AuthorizationCodeAuthorizationFlow < AuthorizationFlow
      expect_params :client_id, :audience
      permit_params :scope, :redirect_uri, :state, :connection, :prompt, :organization, :invitation, :code_challenge, :code_challenge_method, :nonce

      private

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
