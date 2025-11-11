module StandardId
  module Api::Oauth
    module Callback
      class ProvidersController < BaseController
        include StandardId::SocialAuthentication

        skip_before_action :validate_content_type!

        def google
          expect_and_permit!([:id_token], [:id_token])
          handle_social_callback("google",)
        end

        def apple
          expect_and_permit!([:state, :code], [:state, :code])
          handle_social_callback("apple")
        end

        private

        def handle_social_callback(connection)
          original_params = decode_state_params
          user_info = get_user_info_from_provider(connection)
          account = find_or_create_account_from_social(user_info, connection)

          flow = StandardId::Oauth::SocialFlow.new(
            params,
            request,
            account: account,
            connection: connection,
            original_params: original_params
          )

          token_response = flow.execute
          render json: token_response, status: :ok
        end

        def decode_state_params
          encoded_state = params[:state]

          if encoded_state.blank? && params[:id_token].blank? && params[:access_token].blank?
            raise StandardId::InvalidRequestError, "Missing state parameter"
          end

          if encoded_state.blank?
            return {}
          end

          begin
            JSON.parse(Base64.urlsafe_decode64(encoded_state))
          rescue JSON::ParserError, ArgumentError
            raise StandardId::InvalidRequestError, "Invalid state parameter"
          end
        end
      end
    end
  end
end
