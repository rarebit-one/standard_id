module StandardId
  module Web
    module VerifyEmail
      class StartController < BaseController
        # RAR-56: Rate limit verification code generation by IP (10 per hour)
        rate_limit to: StandardId.config.rate_limits.verification_start_per_ip,
                   within: 1.hour,
                   name: "verify-email-ip",
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        # RAR-56: Rate limit verification code generation by email target (3 per
        # 15 minutes). A blank email would collapse into one shared
        # "verify-email:" bucket (`.compact` does not drop a non-nil empty
        # string), throttling everyone; fall the key back to the remote IP when
        # blank so it stays bounded per-IP without poisoning real targets.
        rate_limit to: StandardId.config.rate_limits.verification_start_per_target,
                   within: 15.minutes,
                   by: -> {
                     email = params[:email].to_s.strip.downcase
                     "verify-email:#{email.presence || request.remote_ip}"
                   },
                   name: "verify-email-target",
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        def show
          render plain: "verify email start", status: :ok
        end

        def create
          email = params[:email].to_s.strip.downcase
          if email.blank?
            flash[:alert] = "Please enter your email address"
            render plain: flash[:alert], status: :unprocessable_content and return
          end

          # Issued through the passwordless strategy (validation, retry delay,
          # previous-code invalidation) so delivery goes through the
          # PASSWORDLESS_CODE_GENERATED event like every other OTP. Before 0.43
          # this called the since-removed passwordless_email_sender directly.
          result = StandardId::Otp.issue(
            realm: "verification",
            target: email,
            channel: :email,
            request: request,
            expires_in: 10.minutes
          )
          unless result.success?
            # The body carries the same reason as the flash: a malformed
            # target, the host's username_validator message, or the retry
            # cooldown ("Please wait N seconds ...").
            flash[:alert] = result.error_message
            render plain: result.error_message, status: :unprocessable_content and return
          end

          redirect_to standard_id_web.login_path, notice: "Verification code sent to your email", status: :see_other
        end
      end
    end
  end
end
