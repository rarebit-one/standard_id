module StandardId
  module Web
    class LoginVerifyController < BaseController
      public_controller
      requires_web_mechanism :passwordless_login

      include StandardId::InertiaRendering
      include StandardId::LifecycleHooks

      layout "public"

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

        result = StandardId::Passwordless::VerificationService.verify(
          connection: @otp_data[:connection],
          username: @otp_data[:username],
          code: code,
          request: request
        )

        unless result.success?
          flash.now[:alert] = result.error
          render_with_inertia action: :show, props: verify_page_props, status: :unprocessable_content
          return
        end

        account = result.account
        newly_created = account.previously_new_record?

        session_manager.sign_in_account(account)
        emit_authentication_succeeded(account)

        invoke_after_account_created(account, { mechanism: "passwordless", provider: nil }) if newly_created

        context = { connection: @otp_data[:connection], provider: nil }
        redirect_override = invoke_after_sign_in(account, context)

        session.delete(:standard_id_otp_payload)

        destination = redirect_override || after_authentication_url
        redirect_to destination, status: :see_other, notice: "Successfully signed in"
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
          redirect_to login_path, alert: "Please start the login process"
          return
        end

        begin
          @otp_data = Rails.application.message_verifier(:otp).verify(signed_payload).symbolize_keys
        rescue ActiveSupport::MessageVerifier::InvalidSignature
          session.delete(:standard_id_otp_payload)
          redirect_to login_path, alert: "Your verification session has expired. Please try again."
        end
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
