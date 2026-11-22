module StandardId
  module Api
    # Step-up for bearer clients (StandardId::StepUp), answering the
    # `insufficient_user_authentication` challenge
    # ApiAuthentication#require_recent_authentication! renders:
    #
    #   POST /step_up         → a code goes to the account's verified e-mail
    #                           (or phone); says where, and whether the
    #                           password is needed too
    #   POST /step_up/verify  → { code, password } → a fresh access token whose
    #                           `auth_time` is now; retry the request with it
    #
    # Both need the current access token. The new token keeps that token's
    # client_id, scope and audience, under grant_type "step_up"
    # (oauth.token_lifetimes[:step_up], else the default lifetime). No refresh
    # token is issued: the client keeps its own, and tokens refreshed from it
    # carry the original sign-in's auth_time. Routed only while
    # c.step_up.enabled is true.
    class StepUpController < BaseController
      authenticated_controller

      rate_limit to: StandardId.config.rate_limits.otp_verify_per_ip,
                 within: 15.minutes,
                 name: "api-step-up-verify-ip",
                 only: :verify,
                 store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

      before_action :verify_access_token!

      def create
        result = StandardId::StepUp.start(account: current_account, request: request)
        return render_failure(result) unless result.success? || result.error_code == :cooldown

        render json: {
          channel: result.channel,
          password_required: StandardId::StepUp.password_required?(current_account)
        }, status: :accepted
      end

      def verify
        result = StandardId::StepUp.verify(
          account: current_account,
          code: string_param(:code),
          password: string_param(:password),
          request: request
        )
        return render_failure(result) unless result.success?

        minted = StandardId::TokenMinter.mint(
          account: current_account,
          audience: current_session.aud,
          scopes: Array(current_session.scopes).join(" ").presence,
          client_id: current_session.client_id,
          grant_type: "step_up",
          authenticated_at: Time.current
        )
        render json: {
          access_token: minted.access_token,
          token_type: minted.token_type,
          expires_in: minted.expires_in,
          scope: minted.scope
        }.compact, status: :ok
      end

      private

      def string_param(key)
        value = params[key]
        value.is_a?(String) ? value : nil
      end

      def render_failure(result)
        status = (result.error_code == :rate_limited) ? :too_many_requests : :unprocessable_content
        render json: { error: result.error_code.to_s, error_description: result.error_message }, status: status
      end
    end
  end
end
