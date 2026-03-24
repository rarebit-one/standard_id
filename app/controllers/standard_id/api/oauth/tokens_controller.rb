module StandardId
  module Api
    module Oauth
      class TokensController < BaseController
        public_controller

        skip_before_action :validate_content_type!

        # RAR-51/RAR-60: Rate limit token requests by IP (30 per 15 minutes)
        rate_limit to: StandardId.config.rate_limits.api_token_per_ip,
                   within: 15.minutes,
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        FLOW_STRATEGIES = {
          "client_credentials" => StandardId::Oauth::ClientCredentialsFlow,
          "authorization_code" => StandardId::Oauth::AuthorizationCodeFlow,
          "password" => StandardId::Oauth::PasswordFlow,
          "refresh_token" => StandardId::Oauth::RefreshTokenFlow,
          "passwordless_otp" => StandardId::Oauth::PasswordlessOtpFlow
        }.freeze

        before_action :extract_client_credentials_from_basic_auth

        def create
          response_data = flow_strategy_class.new(flow_strategy_params, request).execute
          render json: response_data, status: :ok
        end

        private

        # Support HTTP Basic authentication for client credentials (RFC 6749 Section 2.3.1)
        def extract_client_credentials_from_basic_auth
          auth_header = request.headers["Authorization"]
          return unless auth_header&.start_with?("Basic ")

          # RFC 6749 Section 2.3: client MUST NOT use more than one authentication method
          if params[:client_id].present? || params[:client_secret].present?
            raise StandardId::InvalidRequestError,
              "Client credentials must be sent via Authorization header OR request body, not both"
          end

          decoded = Base64.strict_decode64(auth_header.split(" ", 2).last)
          client_id, client_secret = decoded.split(":", 2)

          params[:client_id] = CGI.unescape(client_id)
          params[:client_secret] = CGI.unescape(client_secret)
        rescue ArgumentError
          raise StandardId::InvalidClientError, "Invalid Basic authentication encoding"
        end

        def grant_type
          @grant_type ||= params[:grant_type]
        end

        def flow_strategy_class
          @flow_strategy_class ||= begin
            if grant_type.blank?
              raise StandardId::InvalidRequestError, "The grant_type parameter is required"
            end

            klass = FLOW_STRATEGIES[grant_type]
            unless klass
              raise StandardId::UnsupportedGrantTypeError, "Unsupported grant_type: #{grant_type}"
            end
            klass
          end
        end

        def flow_strategy_params
          @flow_strategy_params ||= expect_and_permit!(flow_strategy_class.expected_params, flow_strategy_class.permitted_params)
        end
      end
    end
  end
end
