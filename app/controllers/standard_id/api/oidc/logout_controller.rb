module StandardId
  module Api
    module Oidc
      class LogoutController < ::StandardId::Api::BaseController
        public_controller

        include ActionController::Cookies

        skip_before_action :validate_content_type!

        def show
          session_manager.revoke_current_session!

          if redirect_uri_with_state.present?
            redirect_to redirect_uri_with_state, allow_other_host: true, status: :found
          else
            render json: { message: "You have been logged out" }, status: :ok
          end
        end

        private

        def token_manager
          @token_manager ||= StandardId::Web::TokenManager.new(request)
        end

        def session_manager
          @session_manager ||= StandardId::Web::SessionManager.new(token_manager, request:, session:, cookies:)
        end

        def redirect_uri_with_state
          return unless (uri = params[:post_logout_redirect_uri].presence)
          return unless Array(StandardId.config.allowed_post_logout_redirect_uris).compact.include?(uri)

          if (state = params[:state].presence)
            begin
              parsed = URI.parse(uri)
              params = Rack::Utils.parse_nested_query(parsed.query)
              params["state"] = state
              parsed.query = Rack::Utils.build_query(params)
              parsed.to_s
            rescue URI::InvalidURIError
              "#{uri}#{uri.include?('?') ? '&' : '?'}state=#{CGI.escape(state)}"
            end
          else
            uri
          end
        end
      end
    end
  end
end
