module StandardId
  module Web
    class LoginVerifyController < BaseController
      include StandardId::InertiaRendering
      include StandardId::PasswordlessStrategy

      class OtpVerificationFailed < StandardError; end

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

        # Record failed attempts outside the main transaction so they persist
        challenge = find_active_challenge
        attempts = record_attempt(challenge, code)

        if challenge.blank? || !ActiveSupport::SecurityUtils.secure_compare(challenge.code, code)
          emit_otp_validation_failed(attempts) if challenge.present?

          flash.now[:alert] = "Invalid or expired verification code"
          render_with_inertia action: :show, props: verify_page_props, status: :unprocessable_content
          return
        end

        strategy = strategy_for(@otp_data[:connection])

        begin
          ActiveRecord::Base.transaction do
            # Re-fetch with lock inside transaction to prevent concurrent use
            locked_challenge = StandardId::CodeChallenge.lock.find(challenge.id)
            raise OtpVerificationFailed unless locked_challenge.active?

            account = strategy.find_or_create_account(@otp_data[:username])
            locked_challenge.use!

            emit_otp_validated(account, locked_challenge)
            session_manager.sign_in_account(account)
            emit_authentication_succeeded(account)
          end
        rescue OtpVerificationFailed
          flash.now[:alert] = "Invalid or expired verification code"
          render_with_inertia action: :show, props: verify_page_props, status: :unprocessable_content
          return
        rescue ActiveRecord::RecordInvalid => e
          flash.now[:alert] = "Unable to complete sign in: #{e.record.errors.full_messages.to_sentence}"
          render_with_inertia action: :show, props: verify_page_props, status: :unprocessable_content
          return
        end

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

      def find_active_challenge
        StandardId::CodeChallenge.active.find_by(
          realm: "authentication",
          channel: @otp_data[:connection],
          target: @otp_data[:username]
        )
      end

      def record_attempt(challenge, code)
        return 0 if challenge.blank?
        return 0 if ActiveSupport::SecurityUtils.secure_compare(challenge.code, code)

        attempts = (challenge.metadata["attempts"] || 0) + 1
        challenge.update!(metadata: challenge.metadata.merge("attempts" => attempts))

        max_attempts = StandardId.config.passwordless.max_attempts
        challenge.use! if attempts >= max_attempts

        attempts
      end

      def emit_otp_validated(account, challenge)
        StandardId::Events.publish(
          StandardId::Events::OTP_VALIDATED,
          account: account,
          channel: @otp_data[:connection]
        )
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_VERIFIED,
          code_challenge: challenge,
          account: account,
          channel: @otp_data[:connection]
        )
      end

      def emit_otp_validation_failed(attempts)
        StandardId::Events.publish(
          StandardId::Events::OTP_VALIDATION_FAILED,
          identifier: @otp_data[:username],
          channel: @otp_data[:connection],
          attempts: attempts
        )
        StandardId::Events.publish(
          StandardId::Events::PASSWORDLESS_CODE_FAILED,
          identifier: @otp_data[:username],
          channel: @otp_data[:connection],
          attempts: attempts
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
