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
        before_action :enforce_per_audience_rate_limit, only: :create

        def create
          response_data = flow_strategy_class.new(flow_strategy_params, request).execute
          render json: response_data, status: :ok
        end

        private

        # Per-audience tightening on top of the global api_token_per_ip
        # ceiling (rate_limits.api_token_per_audience_per_ip). Hand-rolled
        # rather than the Rails rate_limit DSL on purpose: the DSL counts
        # every request that reaches the action — a `by:` block returning nil
        # does NOT exempt a request, it collapses into a shared bucket keyed
        # without the discriminator (["rate-limit", scope, name, nil].compact),
        # so one audience's rule would throttle every other audience's
        # traffic. Here only requests that target a configured audience
        # increment that audience's per-IP counter.
        def enforce_per_audience_rate_limit
          limits = StandardId.config.rate_limits.api_token_per_audience_per_ip
          return if limits.blank?

          Array(params[:audience]).each do |audience|
            next unless audience.is_a?(String)

            cap = limits[audience] || limits[audience.to_sym]
            next if cap.blank?

            cache_key = "rate-limit:#{self.class.controller_path}:api_token_per_audience:#{audience}:#{request.remote_ip}"
            count = StandardId::RateLimitHandling::RATE_LIMIT_STORE.increment(cache_key, 1, expires_in: 15.minutes)
            raise ActionController::TooManyRequests if count && count > cap.to_i
          end
        end

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
