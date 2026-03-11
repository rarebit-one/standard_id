module StandardId
  module Web
    module VerifyPhone
      class StartController < BaseController
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
