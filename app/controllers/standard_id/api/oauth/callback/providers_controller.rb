module StandardId
  module Api::Oauth
    module Callback
      class ProvidersController < BaseController
        include StandardId::SocialAuthentication

        skip_before_action :validate_content_type!

        def callback
          provider_response = get_user_info_from_provider(flow: resolve_flow_for(provider.provider_name))
          social_info = provider_response[:user_info]
          provider_tokens = provider_response[:tokens]
          account = find_or_create_account_from_social(social_info)

          flow = StandardId::Oauth::SocialFlow.new(
            params,
            request,
            account:,
            connection: provider.provider_name,
            scopes: params[:scope] || params[:scopes]
          )

          token_response = flow.execute
          run_social_callback(
            provider: provider.provider_name,
            social_info:,
            provider_tokens:,
            account:,
          )
          render json: token_response, status: :ok
        end

        private

        def resolve_flow_for(connection)
          return :mobile unless connection == "apple"

          flow_param = params[:flow].to_s.downcase
          flow_param == "web" ? :web : :mobile
        end
      end
    end
  end
end
