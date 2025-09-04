module StandardId
  module Web
    class LoginController < BaseController
      before_action :redirect_if_authenticated, only: [:show]
      before_action :redirect_if_social_login, only: [:create]

      def show
        @redirect_uri = params[:redirect_uri] || after_authentication_url
        @connection = params[:connection]
      end

      def create
        if sign_in_account(login_params)
          redirect_to params[:redirect_uri] || after_authentication_url, notice: "Successfully signed in"
        else
          flash.now[:alert] = "Invalid email or password"
          render :show, status: :unprocessable_entity
        end
      end

      private

      def redirect_if_authenticated
        redirect_to after_authentication_url if authenticated?
      end

      def redirect_if_social_login
        redirect_to social_login_url, allow_other_host: true if params[:connection].present?
      end

      def social_login_url
        uri = URI.parse("/api/authorize")
        query = {
          response_type: "code",
          client_id: StandardId.config.default_client_id,
          redirect_uri: callback_url,
          connection: params[:connection],
          state: encode_state
        }.to_query
        uri.query = query
        uri.to_s
      end

      def callback_url
        case params[:connection]
        when "google-oauth2"
          auth_callback_google_path
        when "apple"
          auth_callback_apple_path
        end
      end

      def encode_state
        Base64.urlsafe_encode64({
          redirect_uri: params[:redirect_uri] || after_authentication_url,
          timestamp: Time.current.to_i
        }.to_json)
      end

      def login_params
        params.require(:login).permit(:email, :password, :remember_me)
      end
    end
  end
end
