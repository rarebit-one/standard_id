module StandardId
  module Web
    module VerifyPhone
      class StartController < BaseController
        # RAR-56: Rate limit verification code generation by IP (10 per hour)
        rate_limit to: StandardId.config.rate_limits.verification_start_per_ip,
                   within: 1.hour,
                   name: "verify-ip",
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        # RAR-56: Rate limit verification code generation by phone target (3 per 15 minutes)
        rate_limit to: StandardId.config.rate_limits.verification_start_per_target,
                   within: 15.minutes,
                   by: -> { "verify-phone:#{params[:phone_number].to_s.strip}" },
                   name: "verify-target",
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        def show
          render plain: "verify phone start", status: :ok
        end

        def create
          phone = params[:phone_number].to_s.strip
          if phone.blank? || !(phone.match?(/\A\+?[1-9]\d{1,14}\z/))
            flash[:alert] = "Please enter a valid phone number"
            render plain: "invalid phone", status: :unprocessable_content and return
          end

          challenge = StandardId::CodeChallenge.create!(
            realm: "verification",
            channel: "sms",
            target: phone,
            code: generate_otp_code,
            expires_at: 10.minutes.from_now,
            ip_address: StandardId::Utils::IpNormalizer.normalize(request.remote_ip),
            user_agent: request.user_agent
          )

          StandardId.config.passwordless_sms_sender&.call(phone, challenge.code)

          redirect_to standard_id_web.login_path, notice: "Verification code sent via SMS", status: :see_other
        end

        private

        def generate_otp_code
          (SecureRandom.random_number(900_000) + 100_000).to_s
        end
      end
    end
  end
end
