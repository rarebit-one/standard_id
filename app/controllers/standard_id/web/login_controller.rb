module StandardId
  module Web
    class LoginController < BaseController
      include StandardId::InertiaRendering

      layout "public"

      skip_before_action :require_browser_session!, only: [:show, :create]

      before_action :redirect_if_authenticated, only: [:show]
      before_action :redirect_if_social_login, only: [:create]

      def show
        @redirect_uri = params[:redirect_uri] || after_authentication_url
        @connection = params[:connection]

        render_with_inertia props: auth_page_props
      end

      def create
        if sign_in_account(login_params)
          redirect_to params[:redirect_uri] || after_authentication_url, status: :see_other, notice: "Successfully signed in"
        else
          flash.now[:alert] = "Invalid email or password"
          render_with_inertia action: :show, props: auth_page_props, status: :unprocessable_content
        end
      end

      private

      def redirect_if_authenticated
        redirect_to after_authentication_url, status: :see_other, notice: "You are already signed in" if authenticated?
      end

      def redirect_if_social_login
        redirect_with_inertia social_login_url, allow_other_host: true if params[:connection].present?
      end

      def social_login_url
        case params[:connection]
        when "google"
          google_authorization_url
        when "apple"
          apple_authorization_url
        else
          raise StandardId::InvalidRequestError, "Unsupported social connection: #{connection}"
        end
      end

      def google_authorization_url
        StandardId::SocialProviders::Google.authorization_url(
          state: encode_state,
          redirect_uri: auth_callback_google_url
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
