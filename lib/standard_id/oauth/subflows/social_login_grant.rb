module StandardId
  module Oauth
    module Subflows
      class SocialLoginGrant < Base
        def call
          { redirect_to: social_provider_url, status: :found }
        end

        private

        def social_provider_url
          @social_provider_url ||= begin
            connection = params[:connection]
            provider = StandardId::ProviderRegistry.get(connection)

            provider.authorization_url(
              state: encode_state_with_original_params,
              redirect_uri: "#{params[:base_url]}/api/oauth/callback/#{connection}",
              scope: provider.default_scope
            )
          rescue StandardId::ProviderRegistry::ProviderNotFoundError => e
            raise StandardId::InvalidRequestError, e.message
          end
        end

        def encode_state_with_original_params
          original_params = {
            client_id: params[:client_id],
            redirect_uri: params[:redirect_uri],
            scope: params[:scope],
            audience: params[:audience],
            state: params[:state],
            code_challenge: params[:code_challenge],
            code_challenge_method: params[:code_challenge_method]
          }.compact

          # Remove code_challenge_method if code_challenge is not present
          original_params.delete(:code_challenge_method) if original_params[:code_challenge].blank?

          Base64.urlsafe_encode64(JSON.generate(original_params))
        end
      end
    end
  end
end
