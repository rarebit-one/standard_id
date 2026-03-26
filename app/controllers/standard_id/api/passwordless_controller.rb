module StandardId
  module Api
    class PasswordlessController < BaseController
      public_controller

      include StandardId::PasswordlessFlow

      # RAR-60: Rate limit OTP initiation by IP (10 per hour)
      rate_limit to: StandardId.config.rate_limits.api_passwordless_start_per_ip,
                 within: 1.hour,
                 name: "passwordless-ip",
                 only: :start,
                 store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

      # RAR-60: Rate limit OTP initiation by target (5 per 15 minutes)
      rate_limit to: StandardId.config.rate_limits.api_passwordless_start_per_target,
                 within: 15.minutes,
                 by: -> { "api-passwordless:#{(params[:username] || params[:email] || params[:phone_number]).to_s.strip.downcase}" },
                 name: "passwordless-target",
                 only: :start,
                 store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

      def start
        raise StandardId::InvalidRequestError, "username, email, or phone_number parameter is required" if start_params[:username].blank?

        generate_passwordless_otp(email: start_params[:username], connection: start_params[:connection])

        render json: { message: "Code sent successfully" }, status: :ok
      end

      private

      def start_params
        return @start_params if @start_params.present?

        params.expect(:connection)
        permitted = params.permit(:connection, :username, :email, :phone_number)

        @start_params = {
          connection: permitted[:connection],
          username: permitted[:username] || permitted[:email] || permitted[:phone_number]
        }
      end
    end
  end
end
