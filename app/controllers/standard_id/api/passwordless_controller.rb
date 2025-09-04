module StandardId
  module Api
    class PasswordlessController < BaseController
      STRATEGY_MAP = {
        "email" => StandardId::Passwordless::EmailStrategy,
        "sms"   => StandardId::Passwordless::SmsStrategy
      }.freeze

      def start
        raise StandardId::InvalidRequestError, "username, email, or phone_number parameter is required" if start_params[:username].blank?

        strategy_for(start_params[:connection]).start!(start_params)

        render json: { message: "Code sent successfully" }, status: :ok
      end

      private

      def strategy_for(connection)
        klass = STRATEGY_MAP[connection]
        raise StandardId::InvalidRequestError, "Unsupported connection type: #{connection}" unless klass
        klass.new(request)
      end

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
