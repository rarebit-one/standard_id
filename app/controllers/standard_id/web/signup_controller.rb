module StandardId
  module Web
    class SignupController < BaseController
      public_controller

      include StandardId::InertiaRendering

      layout "public"

      skip_before_action :require_browser_session!, only: [:show, :create]

      before_action :redirect_if_authenticated, only: [:show]
      before_action :redirect_if_social_login, only: [:create]

      def show
        @redirect_uri = params[:redirect_uri] || after_authentication_url
        @connection = params[:connection] # For social login detection

        render_with_inertia props: auth_page_props
      end

      def create
        handle_password_signup
      end

      private

      def redirect_if_authenticated
        redirect_to after_authentication_url if authenticated?
      end

      def redirect_if_social_login
        redirect_with_inertia social_signup_url, allow_other_host: true if params[:connection].present?
      end

      def handle_password_signup
        form = StandardId::Web::SignupForm.new(signup_params)

        if form.submit
          session_manager.sign_in_account(form.account)
          redirect_to params[:redirect_uri] || after_authentication_url,
                      notice: "Account created successfully"
        else
          @redirect_uri = params[:redirect_uri] || after_authentication_url
          @connection = params[:connection]
          flash.now[:alert] = form.errors.full_messages.join(", ")
          render_with_inertia action: :show, props: auth_page_props(errors: form.errors.to_hash), status: :unprocessable_content
        end
      end

      def social_signup_url
        # Same as login - social providers handle signup/login automatically
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
        connection = params[:connection]
        provider = StandardId::ProviderRegistry.get(connection)
        "#{request.base_url}#{provider.callback_path}"
      end

      def encode_state
        Base64.urlsafe_encode64({
          redirect_uri: params[:redirect_uri] || after_authentication_url,
          timestamp: Time.current.to_i
        }.to_json)
      end

      def account_params
        # Add any additional account fields as needed
        {}
      end

      def signup_params
        params.require(:signup).permit(:email, :password, :password_confirmation)
      end
    end
  end
end
