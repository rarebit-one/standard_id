module StandardId
  module Web
    class LoginController < BaseController
      public_controller

      include StandardId::InertiaRendering
      include StandardId::Web::SocialLoginParams
      include StandardId::PasswordlessFlow
      include StandardId::LifecycleHooks

      layout "public"

      # RAR-51: Rate limit login attempts by IP (20 per 15 minutes)
      rate_limit to: StandardId.config.rate_limits.password_login_per_ip,
                 within: 15.minutes,
                 name: "login-ip",
                 only: :create,
                 store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

      # RAR-51: Rate limit login attempts by email target (5 per 15 minutes)
      rate_limit to: StandardId.config.rate_limits.password_login_per_email,
                 within: 15.minutes,
                 by: -> { "login-email:#{params.dig(:login, :email).to_s.strip.downcase}" },
                 name: "login-email",
                 only: :create,
                 store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

      skip_before_action :require_browser_session!, only: [:show, :create]

      before_action :redirect_if_authenticated, only: [:show]
      before_action :redirect_if_social_login, only: [:create]

      def show
        @redirect_uri = params[:redirect_uri] || after_authentication_url
        @connection = params[:connection]

        render_with_inertia props: auth_page_props(passwordless_enabled: passwordless_enabled?)
      end

      def create
        if passwordless_enabled?
          handle_passwordless_login
        else
          handle_password_login
        end
      end

      private

      def passwordless_enabled?
        StandardId.config.web.passwordless_login
      end

      def handle_password_login
        return head(:not_found) unless StandardId.config.web.password_login

        result = sign_in_account(login_params) { |account|
          invoke_before_sign_in(account, { mechanism: "password", provider: nil })
        }

        if result
          context = { mechanism: "password", provider: nil }
          redirect_override = invoke_after_sign_in(current_account, context)
          destination = redirect_override || params[:redirect_uri] || after_authentication_url
          redirect_to destination, status: :see_other, notice: "Successfully signed in"
        else
          flash.now[:alert] = "Invalid email or password"
          render_with_inertia action: :show, props: auth_page_props(passwordless_enabled: passwordless_enabled?), status: :unprocessable_content
        end
      rescue StandardId::AuthenticationDenied => e
        handle_authentication_denied(e)
      end

      def handle_passwordless_login
        username = login_params[:email].to_s.strip.downcase
        connection = StandardId.config.passwordless.connection

        if username.blank?
          flash.now[:alert] = "Please enter your email address"
          render_with_inertia action: :show, props: auth_page_props(passwordless_enabled: passwordless_enabled?), status: :unprocessable_content
          return
        end

        begin
          generate_passwordless_otp(username: username, connection: connection)
        rescue StandardId::InvalidRequestError => e
          flash.now[:alert] = e.message
          render_with_inertia action: :show, props: auth_page_props(passwordless_enabled: passwordless_enabled?), status: :unprocessable_content
          return
        end

        code_ttl = StandardId.config.passwordless.code_ttl
        signed_payload = Rails.application.message_verifier(:otp).generate(
          { username: username, connection: connection },
          expires_in: code_ttl.seconds
        )
        session[:standard_id_otp_payload] = signed_payload
        session[:return_to_after_authenticating] = params[:redirect_uri] if params[:redirect_uri].present?

        redirect_to login_verify_path, status: :see_other
      end

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
        social_params = request.parameters.except("controller", "action", "format", "authenticity_token", "commit", "login").to_h.deep_dup
        # Include scope from route defaults so it survives the OAuth redirect/callback round trip
        scope = request.path_parameters[:scope]
        social_params["scope"] = scope.to_s if scope.present?
        social_params
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
