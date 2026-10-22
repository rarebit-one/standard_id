module StandardId
  module Web
    module VerifyEmail
      class ConfirmController < BaseController
        # Per-IP limit on code confirmation (20 per 15 minutes, shared with OTP
        # verify). Otp.verify's per-challenge attempt cap alone doesn't stop
        # distributed guessing across many challenges.
        rate_limit to: StandardId.config.rate_limits.otp_verify_per_ip,
                   within: 15.minutes,
                   name: "verify-email-confirm-ip",
                   only: [:show, :update],
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        def show
          return redirect_to(standard_id_web.login_path, alert: "Invalid or expired verification code") if target.blank? || code.blank?
          # Does not check the code: a GET that answered valid/invalid would be
          # a guessing oracle that never counts an attempt. PATCH verifies.
          render plain: "verify email confirm", status: :ok
        end

        def update
          # Otp.verify locks the challenge, compares in constant time, counts
          # the failed attempt and burns the challenge at the per-challenge cap.
          return redirect_to(standard_id_web.login_path, alert: "Invalid or expired verification code") if code.blank?

          result = StandardId::Otp.verify(realm: "verification", target: target, code: code, channel: :email, request: request)
          return redirect_to(standard_id_web.login_path, alert: result.error) unless result.success?

          StandardId::EmailIdentifier.find_by(value: target)&.verify!

          redirect_to standard_id_web.login_path, notice: "Your email has been verified. Please sign in.", status: :see_other
        end

        private

        def target
          @target ||= params[:email].to_s.strip.downcase
        end

        def code
          params[:code].to_s
        end
      end
    end
  end
end
