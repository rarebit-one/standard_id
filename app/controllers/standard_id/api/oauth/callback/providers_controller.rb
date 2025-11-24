module StandardId
  module Api::Oauth
    module Callback
      class ProvidersController < BaseController
        include StandardId::SocialAuthentication

        skip_before_action :validate_content_type!

        def google
          expect_and_permit!([], [:id_token, :code])
          handle_social_callback("google")
        end

        def apple
          expect_and_permit!([], [:id_token, :code, :state, :flow])
          handle_social_callback("apple")
        end

        private

        def handle_social_callback(connection)
          original_params = decode_state_params
          flow = resolve_flow_for(connection)
          user_info = get_user_info_from_provider(connection, flow: flow)
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
          flow_param == "mobile" ? :mobile : :web
        end
      end
    end
  end
end
