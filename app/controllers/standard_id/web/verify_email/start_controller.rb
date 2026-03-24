module StandardId
  module Web
    module VerifyEmail
      class StartController < BaseController
        # RAR-56: Rate limit verification code generation by IP (10 per hour)
        rate_limit to: StandardId.config.rate_limits.verification_start_per_ip,
                   within: 1.hour,
                   name: "verify-ip",
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        # RAR-56: Rate limit verification code generation by email target (3 per 15 minutes)
        rate_limit to: StandardId.config.rate_limits.verification_start_per_target,
                   within: 15.minutes,
                   by: -> { "verify-email:#{params[:email].to_s.strip.downcase}" },
                   name: "verify-target",
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        def show
          render plain: "verify email start", status: :ok
        end

        def create
          email = params[:email].to_s.strip.downcase
          if email.blank?
            flash[:alert] = "Please enter your email address"
            render plain: "missing email", status: :unprocessable_content and return
          end

          challenge = StandardId::CodeChallenge.create!(
            realm: "verification",
            channel: "email",
            target: email,
            code: generate_otp_code,
            expires_at: 10.minutes.from_now,
            ip_address: StandardId::Utils::IpNormalizer.normalize(request.remote_ip),
            user_agent: request.user_agent
          )

          StandardId.config.passwordless_email_sender&.call(email, challenge.code)

          redirect_to standard_id_web.login_path, notice: "Verification code sent to your email", status: :see_other
        end

        private

        def generate_otp_code
          (SecureRandom.random_number(900_000) + 100_000).to_s
        end
      end
    end
  end
end
