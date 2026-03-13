module StandardId
  module Api
    class BaseController < ActionController::API
      include StandardId::ControllerPolicy
      include StandardId::ApiAuthentication
      include StandardId::SetCurrentRequestDetails

      before_action -> { Current.scope = :api if defined?(::Current) }
      before_action :validate_content_type!

      after_action :set_no_store_headers

      rescue_from StandardId::NotAuthenticatedError, with: :handle_not_authenticated
      rescue_from StandardId::InvalidSessionError, with: :handle_invalid_session
      rescue_from StandardId::OAuthError, with: :handle_oauth_error

      protected

      def validate_content_type!
        return if request.media_type&.match?(%r{\Aapplication\/(.+\+)?json\z})
        raise StandardId::InvalidRequestError, "Content-Type must be application/json or application/*+json"
      end

      def set_no_store_headers
        response.headers["Cache-Control"] = "no-store"
        response.headers["Pragma"] = "no-cache"
      end

      def expect_and_permit!(expected_keys, permitted_keys)
        params.expect(expected_keys)
        params.permit(*permitted_keys)
      rescue ActionController::ParameterMissing => e
        raise StandardId::InvalidRequestError, "The #{e.param} parameter is required"
      end

      def handle_not_authenticated(error)
        render_bearer_unauthorized!(error_description: error.message.presence || default_invalid_token_message)
      end

      def handle_invalid_session(error)
        render_bearer_unauthorized!(error_description: default_invalid_token_message)
      end

      def handle_oauth_error(error)
        render json: {
          error: error.oauth_error_code,
          error_description: error.message
        }, status: error.http_status
      end

      def render_bearer_unauthorized!(error_description: default_invalid_token_message, error_code: "invalid_token")
        response.set_header(
          "WWW-Authenticate",
          %Q(Bearer realm="StandardId", error="#{error_code}", error_description="#{error_description}")
        )
        render json: { error: error_code, error_description: error_description }, status: :unauthorized
      end

      def default_invalid_token_message
        "The access token is invalid or has expired"
      end
    end
  end
end
