module StandardId
  module Api
    module Oauth
      class TokensController < BaseController
        FLOW_STRATEGIES = {
          "client_credentials" => StandardId::Oauth::ClientCredentialsFlow,
          "authorization_code" => StandardId::Oauth::AuthorizationCodeFlow,
          "password" => StandardId::Oauth::PasswordFlow,
          "refresh_token" => StandardId::Oauth::RefreshTokenFlow
        }.freeze

        def create
          response_data = flow_strategy_class.new(flow_strategy_params, request).execute
          render json: response_data, status: :ok
        end

        private

        def grant_type
          @grant_type ||= params[:grant_type]
        end

        def flow_strategy_class
          @flow_strategy_class ||= begin
            if grant_type.blank?
              raise StandardId::InvalidRequestError, "The grant_type parameter is required"
            end

            klass = FLOW_STRATEGIES[grant_type]
            unless klass
              raise StandardId::UnsupportedGrantTypeError, "Unsupported grant_type: #{grant_type}"
            end
            klass
          end
        end

        def flow_strategy_params
          @flow_strategy_params ||= expect_and_permit!(flow_strategy_class.expected_params, flow_strategy_class.permitted_params)
        end
      end
    end
  end
end
