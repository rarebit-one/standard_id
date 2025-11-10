module StandardId
  module Web
    class LoginController < BaseController
      layout "public"

      skip_before_action :require_browser_session!, only: [:show, :create]

      before_action :redirect_if_authenticated, only: [:show]
      before_action :redirect_if_social_login, only: [:create]

      def show
        @redirect_uri = params[:redirect_uri] || after_authentication_url
        @connection = params[:connection]
      end

      def create
        if sign_in_account(login_params)
          redirect_to params[:redirect_uri] || after_authentication_url, status: :see_other, notice: "Successfully signed in"
        else
          flash.now[:alert] = "Invalid email or password"
          render :show, status: :unprocessable_content
        end
      end

      private

      def redirect_if_authenticated
        redirect_to after_authentication_url, status: :see_other, notice: "You are already signed in" if authenticated?
      end

      def redirect_if_social_login
        redirect_to social_login_url, allow_other_host: true if params[:connection].present?
      end

      def social_login_url
        connection = params[:connection]
        if StandardId::SocialProviders::Google.supported_connection?(connection)
          return google_authorization_url(connection)
        elsif connection == "apple"
          return apple_authorization_url
        end

        raise StandardId::InvalidRequestError, "Unsupported social connection: #{params[:connection]}"
      end

      def google_authorization_url(connection)
        StandardId::SocialProviders::Google.authorization_url(
          state: encode_state,
          redirect_uri: auth_callback_google_url,
          connection: connection
        )
      end

      def apple_authorization_url
        StandardId::SocialProviders::Apple.authorization_url(
          state: encode_state,
          redirect_uri: auth_callback_apple_url
        )
      end

      def encode_state
        Base64.urlsafe_encode64({
          redirect_uri: params[:redirect_uri] || after_authentication_url,
          timestamp: Time.current.to_i
        }.compact.to_json)
      end

      def login_params
        params.require(:login).permit(:email, :password, :remember_me)
      end
    end
  end
end
