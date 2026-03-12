module StandardId
  module Web
    class LoginVerifyController < BaseController
      public_controller

      include StandardId::InertiaRendering

      layout "public"

      skip_before_action :require_browser_session!, only: [:show, :update]

      before_action :ensure_passwordless_enabled!
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

        session_manager.sign_in_account(result.account)
        emit_authentication_succeeded(result.account)

        session.delete(:standard_id_otp_payload)

        redirect_to after_authentication_url, status: :see_other, notice: "Successfully signed in"
      end

      private

      def ensure_passwordless_enabled!
        return if StandardId.config.passwordless.enabled

        session.delete(:standard_id_otp_payload)
        redirect_to login_path, alert: "Passwordless login is not available"
      end

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
