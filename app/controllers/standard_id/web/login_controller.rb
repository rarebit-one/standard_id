module StandardId
  module Web
    class LoginController < BaseController
      include StandardId::InertiaRendering
      include StandardId::Web::SocialLoginParams


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
        return unless params[:connection].present?

        provider = StandardId::ProviderRegistry.get(params[:connection].to_s)

        state = generate_oauth_token
        nonce = provider_supports_nonce?(provider) ? generate_oauth_token : nil

        store_oauth_request(
          state:,
          nonce:,
          params: extract_social_login_params
        )

        callback_url = "#{request.base_url}#{provider.callback_path}"
        extra_params = extract_oauth_params(provider)

        # Add nonce to OAuth params if provider supports it
        extra_params[:nonce] = nonce if nonce.present?

        url = provider.authorization_url(
          state:,
          redirect_uri: callback_url,
          **extra_params.compact
        )

        redirect_with_inertia url, allow_other_host: true
      rescue StandardId::ProviderRegistry::ProviderNotFoundError => e
        raise StandardId::InvalidRequestError, e.message
      end

      def extract_social_login_params
        request.parameters.except("controller", "action", "format", "authenticity_token", "commit", "login").to_h.deep_dup
      end

      def extract_oauth_params(provider)
        supported_params = provider.try(:supported_authorization_params)
        return {} if supported_params.blank?

        params.permit(*supported_params).to_h.compact.symbolize_keys
      end

      def generate_oauth_token
        SecureRandom.urlsafe_base64(32)
      end

      def provider_supports_nonce?(provider)
        provider.supported_authorization_params.include?(:nonce)
      end

      def login_params
        params.require(:login).permit(:email, :password, :remember_me)
      end
    end
  end
end
