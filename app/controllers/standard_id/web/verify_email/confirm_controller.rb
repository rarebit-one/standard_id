module StandardId
  module Web
    module VerifyEmail
      class ConfirmController < BaseController
        # Per-IP limit on code confirmation (20 per 15 minutes, shared with OTP
        # verify). The per-challenge attempt cap alone doesn't stop distributed
        # guessing across many challenges; both show and update probe a code.
        rate_limit to: StandardId.config.rate_limits.otp_verify_per_ip,
                   within: 15.minutes,
                   name: "verify-email-confirm-ip",
                   only: [:show, :update],
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        before_action :prepare_code_challenge

        def show
          return redirect_to(standard_id_web.login_path, alert: "Invalid or expired verification code") if @challenge.nil?
          render plain: "verify email confirm", status: :ok
        end

        def update
          return redirect_to(standard_id_web.login_path, alert: "Invalid or expired verification code") if @challenge.nil?

          identifier = StandardId::EmailIdentifier.find_by(value: @challenge.target)
          if identifier.present?
            identifier.verify!
          end
          @challenge.use!

          redirect_to standard_id_web.login_path, notice: "Your email has been verified. Please sign in.", status: :see_other
        end

        private

        def prepare_code_challenge
          email = params[:email].to_s.strip.downcase
          code = params[:code].to_s
          return @challenge = nil if email.blank? || code.blank?

          @challenge = StandardId::CodeChallenge.active.find_by(
            realm: "verification",
            channel: "email",
            target: email,
            code: code
          )
        end
      end
    end
  end
end
