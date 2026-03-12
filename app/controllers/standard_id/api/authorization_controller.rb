module StandardId
  module Api
    class AuthorizationController < BaseController
      public_controller

      include ActionController::Cookies

      skip_before_action :validate_content_type!

      before_action :redirect_to_login, if: :requires_authentication?

      FLOW_STRATEGIES = {
        "code" => StandardId::Oauth::AuthorizationCodeAuthorizationFlow,
        "token" => StandardId::Oauth::ImplicitAuthorizationFlow,
        "token id_token" => StandardId::Oauth::ImplicitAuthorizationFlow
      }.freeze

      def show
        response_data = flow_strategy_class.new(flow_strategy_params, request, current_account: current_account).execute

        if response_data[:redirect_to]
          redirect_to response_data[:redirect_to], status: response_data[:status] || :found, allow_other_host: true
        else
          render json: response_data, status: :ok
        end
      end

      private

      def response_type
        @response_type ||= params[:response_type]
      end

      def flow_strategy_class
        @flow_strategy_class ||= begin
          if response_type.blank?
            raise StandardId::InvalidRequestError, "The response_type parameter is required"
          end

          klass = FLOW_STRATEGIES[response_type]
          unless klass
            raise StandardId::UnsupportedResponseTypeError, "Unsupported response_type: #{response_type}"
          end
          klass
        end
      end

      def flow_strategy_params
        @flow_strategy_params ||= expect_and_permit!(flow_strategy_class.expected_params, flow_strategy_class.permitted_params)
      end

      def requires_authentication?
        FLOW_STRATEGIES.key?(response_type) && !social_login?
      end

      def social_login?
        params[:connection].present?
      end

      def redirect_to_login
        return if current_account.present?

        base_login_url = StandardId.config.login_url.presence || "/login"
        separator = base_login_url.include?("?") ? "&" : "?"
        login_url = "#{base_login_url}#{separator}redirect_uri=#{CGI.escape(request.url)}"

        redirect_to login_url, allow_other_host: true, status: :found
      end

      def current_account
        @current_account ||= begin
          token_manager = StandardId::Web::TokenManager.new(request)
          session_manager = StandardId::Web::SessionManager.new(token_manager, request: request, session: session, cookies: cookies)
          session_manager.current_account
        end
      end
    end
  end
end
