module StandardId
  module Web
    module VerifyPhone
      class ConfirmController < BaseController
        # Per-IP limit on code confirmation (20 per 15 minutes, shared with OTP
        # verify). The per-challenge attempt cap alone doesn't stop distributed
        # guessing across many challenges; both show and update probe a code.
        rate_limit to: StandardId.config.rate_limits.otp_verify_per_ip,
                   within: 15.minutes,
                   name: "verify-phone-confirm-ip",
                   only: [:show, :update],
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        before_action :prepare_code_challenge

        def show
          return redirect_to(standard_id_web.login_path, alert: "Invalid or expired verification code") if @challenge.nil?
          render plain: "verify phone confirm", status: :ok
        end

        def update
          return redirect_to(standard_id_web.login_path, alert: "Invalid or expired verification code") if @challenge.nil?

          identifier = StandardId::PhoneNumberIdentifier.find_by(value: @challenge.target)
          if identifier.present?
            identifier.verify!
          end
          @challenge.use!

          redirect_to standard_id_web.login_path, notice: "Your phone number has been verified. Please sign in.", status: :see_other
        end

        private

        def prepare_code_challenge
          phone = params[:phone_number].to_s.strip
          code = params[:code].to_s
          return @challenge = nil if phone.blank? || code.blank?

          @challenge = StandardId::CodeChallenge.active.find_by(
            realm: "verification",
            channel: "sms",
            target: phone,
            code: code
          )
        end
      end
    end
  end
end
