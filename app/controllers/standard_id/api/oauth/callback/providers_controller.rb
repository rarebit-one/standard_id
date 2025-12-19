module StandardId
  module Api::Oauth
    module Callback
      class ProvidersController < BaseController
        include StandardId::SocialAuthentication

        skip_before_action :validate_content_type!

        def callback
          original_params = decode_state_params
          provider_response = get_user_info_from_provider(flow: resolve_flow_for(provider.provider_name))
          social_info = provider_response[:user_info]
          provider_tokens = provider_response[:tokens]
          account = find_or_create_account_from_social(social_info)

          flow = StandardId::Oauth::SocialFlow.new(
            params,
            request,
            account: account,
            connection: provider.provider_name,
            original_params: original_params
          )

          token_response = flow.execute
          run_social_callback(
            provider: provider.provider_name,
            social_info: social_info,
            provider_tokens: provider_tokens,
            account: account,
          )
          render json: token_response, status: :ok
        end

        private

        def decode_state_params
          encoded_state = params[:state]

          return {} if encoded_state.blank?

          begin
            JSON.parse(Base64.urlsafe_decode64(encoded_state))
          rescue JSON::ParserError, ArgumentError
            raise StandardId::InvalidRequestError, "Invalid state parameter"
          end
        end

        def resolve_flow_for(connection)
          return :mobile unless connection == "apple"

          flow_param = params[:flow].to_s.downcase
          flow_param == "web" ? :web : :mobile
        end
      end
    end
  end
end
