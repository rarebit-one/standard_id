module StandardId
  module Api
    # Email + password sign-up and sign-in for JSON clients. Drawn only while
    # `c.email_password.enabled` is true; the rules are in StandardId::EmailPassword.
    #
    #   POST /auth/register             { email, password, name? }
    #     202 { status: "verification_required", email }
    #   POST /auth/login                { email, password }
    #     200 token response
    #   POST /auth/verify-email         { email, code, password }
    #     200 token response
    #   POST /auth/verify-email/resend  { email, password }
    #     202 { status: "verification_sent" }, ALWAYS
    #   POST /auth/password/forgot      { email }
    #     202 { status: "reset_requested" }, ALWAYS
    #   POST /auth/password/reset       { token, password, password_confirmation? }
    #     200 { status: "password_reset" }
    #
    # Token responses are the TokenResponse every other grant returns, and
    # refresh through /oauth/token with `c.email_password.token_client_id`.
    #
    # Failures are StandardId::EmailPasswordError codes, rendered as
    # `{ error, error_description, details? }` with the code's status, or by
    # `c.email_password.error_renderer` when set.
    #
    # Every action is limited per client key (`c.email_password.client_key`,
    # default the remote IP) and, where there is one, per target email.
    class EmailPasswordController < BaseController
      public_controller

      RATE_LIMITS = {
        register: { ip: [:signup_per_ip, 1.hour], email: [:verification_start_per_target, 15.minutes] },
        login: { ip: [:login_per_ip, 15.minutes], email: [:login_per_email, 15.minutes] },
        verify: { ip: [:otp_verify_per_ip, 15.minutes], email: [:email_password_verify_per_email, 15.minutes] },
        resend: { ip: [:verification_start_per_ip, 1.hour], email: [:verification_start_per_target, 15.minutes] },
        forgot_password: { ip: [:password_reset_start_per_ip, 1.hour], email: [:password_reset_start_per_target, 15.minutes] },
        reset_password: { ip: [:email_password_reset_per_ip, 15.minutes] }
      }.freeze

      RATE_LIMITS.each do |action, limits|
        limits.each do |kind, (field, within)|
          rate_limit to: StandardId.config.rate_limits.public_send(field),
                     within: within,
                     name: "email-password-#{action}-#{kind}",
                     only: action,
                     by: kind == :ip ? -> { rate_limit_client_key } : -> { "email:#{rate_limit_email.presence || rate_limit_client_key}" },
                     with: -> { raise StandardId::EmailPasswordError.new(:rate_limited, retry_after: within.to_i) },
                     store: StandardId::RateLimitHandling::RATE_LIMIT_STORE
        end
      end

      rescue_from StandardId::EmailPasswordError, with: :render_email_password_error

      def register
        email = StandardId::EmailPassword::Registration.call(
          email: params[:email], password: params[:password], name: params[:name], request: request
        )
        render json: { status: "verification_required", email: email }, status: :accepted
      end

      def login
        StandardId::EmailPassword::Authentication.call(email: params[:email], password: params[:password]) do |account|
          render_tokens_for(account)
        end
      end

      def verify
        account = StandardId::EmailPassword::Verification.verify!(
          email: params[:email], code: params[:code], password: params[:password], request: request
        )
        render_tokens_for(account)
      end

      def resend
        StandardId::EmailPassword::Verification.send_code(
          email: params[:email], password: params[:password], request: request
        )
        render json: { status: "verification_sent" }, status: :accepted
      end

      def forgot_password
        StandardId::EmailPassword::PasswordReset.request(email: params[:email], request: request)
        render json: { status: "reset_requested" }, status: :accepted
      end

      def reset_password
        StandardId::EmailPassword::PasswordReset.complete!(
          token: params[:token],
          password: params[:password],
          password_confirmation: params.key?(:password_confirmation) ? params[:password_confirmation] : nil
        )
        render json: { status: "password_reset" }, status: :ok
      end

      private

      def render_tokens_for(account)
        render json: StandardId::EmailPassword::TokenFlow.new(account: account, request: request).execute, status: :ok
      rescue StandardId::AccountDeactivatedError, StandardId::AccountLockedError
        # The same answer as a wrong password: this endpoint must not reveal
        # the account's state.
        raise StandardId::EmailPasswordError.new(:invalid_credentials)
      rescue StandardId::LoginMethodDenied => e
        # The password was right, so the policy's reason may be shown.
        raise StandardId::EmailPasswordError.new(:login_method_denied, e.message)
      end

      def render_email_password_error(error)
        response.set_header("Retry-After", error.retry_after.to_i.to_s) if error.retry_after.to_i.positive?

        renderer = StandardId::EmailPassword.config.error_renderer
        body = if renderer.respond_to?(:call)
          StandardId::EmailPassword.call_hook(renderer, error: error, request: request)
        else
          { error: error.code.to_s, error_description: error.message, details: error.details.presence }.compact
        end
        render json: body, status: error.http_status
      end

      def rate_limit_client_key
        StandardId::EmailPassword.client_key(request).to_s
      end

      def rate_limit_email
        StandardId::EmailPassword.normalize_email(params[:email])
      end
    end
  end
end
