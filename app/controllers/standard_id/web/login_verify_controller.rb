module StandardId
  module Web
    class LoginVerifyController < BaseController
      public_controller
      requires_web_mechanism :passwordless_login

      include StandardId::InertiaRendering
      include StandardId::PasswordlessFlow
      include StandardId::LifecycleHooks

      layout "public"

      # RAR-60: Rate limit OTP verification attempts by IP (20 per 15 minutes)
      rate_limit to: StandardId.config.rate_limits.otp_verify_per_ip,
                 within: 15.minutes,
                 name: "otp-verify-ip",
                 only: :update,
                 store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

      skip_before_action :require_browser_session!, only: [:show, :update]
      before_action :redirect_if_authenticated, only: [:show]
      before_action :require_otp_payload!

      def show
        render_with_inertia props: verify_page_props
      end

      def update
        code = params[:code].to_s.strip

        if code.blank?
          flash.now[:alert] = "Please enter the verification code"
          render_with_inertia action: :show, props: verify_page_props, status: :unprocessable_content
          return
        end

        result = verify_passwordless_otp(
          username: @otp_data[:username],
          code: code,
          connection: @otp_data[:connection],
          allow_registration: passwordless_registration_enabled?
        )

        unless result.success?
          flash.now[:alert] = result.error
          render_with_inertia action: :show, props: verify_page_props, status: :unprocessable_content
          return
        end

        account = result.account
        newly_created = account.previously_new_record?

        invoke_before_sign_in(account, { mechanism: "passwordless", provider: nil })

        session_manager.sign_in_account(account, scope_name: request.path_parameters[:scope])
        emit_authentication_succeeded(account)

        if newly_created
          emit_passwordless_account_created(account)
          invoke_after_account_created(account, { mechanism: "passwordless", provider: nil })
        end

        # Peek (don't pop) session[:return_to_after_authenticating] — after_authentication_url
        # consumes it below when redirect_override is nil, so deleting it here would lose the
        # destination for hosts whose after_sign_in hook defers to the originator's redirect_uri.
        context = {
          mechanism: "passwordless",
          provider: nil,
          redirect_uri: session[:return_to_after_authenticating]
        }
        redirect_override = invoke_after_sign_in(account, context)

        session.delete(:standard_id_otp_payload)

        # after_authentication_url returns whatever was stashed in
        # session[:return_to_after_authenticating] — which could be an attacker-controlled
        # URL set by handle_passwordless_login from params[:redirect_uri]. string_param
        # blocks Array/Hash but not "https://evil.com/phish". Validate before redirect.
        fallback = after_authentication_url
        destination = redirect_override || (safe_destination?(fallback) ? fallback : safe_post_signin_default)
        redirect_after_authentication destination, notice: "Successfully signed in"
      rescue StandardId::AuthenticationDenied => e
        session.delete(:standard_id_otp_payload)
        handle_authentication_denied(e, account: account, newly_created: newly_created)
      end

      private

      def redirect_if_authenticated
        redirect_to after_authentication_url, status: :see_other if authenticated?
      end

      def require_otp_payload!
        signed_payload = session[:standard_id_otp_payload]

        if signed_payload.blank?
          redirect_to engine_path(login_path), alert: "Please start the login process"
          return
        end

        begin
          @otp_data = Rails.application.message_verifier(:otp).verify(signed_payload).symbolize_keys
        rescue ActiveSupport::MessageVerifier::InvalidSignature
          session.delete(:standard_id_otp_payload)
          redirect_to engine_path(login_path), alert: "Your verification session has expired. Please try again."
        end
      end

      def passwordless_registration_enabled?
        StandardId.config.web.passwordless_registration
      end

      def emit_passwordless_account_created(account)
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_ACCOUNT_CREATED,
          account: account,
          channel: @otp_data[:connection],
          identifier: @otp_data[:username]
        )
      end

      def emit_authentication_succeeded(account)
        StandardId::Events.publish(
          StandardId::Events::AUTHENTICATION_SUCCEEDED,
          account: account,
          auth_method: "passwordless_otp",
          session_type: "browser"
        )
      end

      def verify_page_props
        {
          flash: {
            notice: flash[:notice],
            alert: flash[:alert]
          }.compact
        }
      end
    end
  end
end
