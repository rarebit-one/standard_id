module StandardId
  module Api
    class ProvidersController < BaseController
      include StandardId::SocialAuthentication

      skip_before_action :validate_content_type!

      def google
        expect_and_permit!([:state, :code], [:state, :code])
        handle_social_callback("google-oauth2")
      end

      def google_android
        expect_and_permit!([:id_token, :access_token], [:id_token, :access_token])
        handle_social_callback("google-oauth2-android")
      end

      def google_ios
        expect_and_permit!([:id_token, :access_token], [:id_token, :access_token])
        handle_social_callback("google-oauth2-ios")
      end

      def apple
        expect_and_permit!([:state, :code], [:state, :code])
        handle_social_callback("apple")
      end

      private

      def handle_social_callback(connection)
        original_params = decode_state_params

        user_info = if connection.in?(["google-oauth2-android", "google-oauth2-ios"])
          get_user_info_from_provider(connection)
        else
          redirect_uri = connection == "apple" ? oauth_callback_apple_url : oauth_callback_google_url
          get_user_info_from_provider(connection, redirect_uri: redirect_uri)
        end

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
