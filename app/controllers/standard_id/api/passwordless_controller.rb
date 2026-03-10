module StandardId
  module Api
    class PasswordlessController < BaseController
      include StandardId::PasswordlessStrategy

      def start
        raise StandardId::InvalidRequestError, "username, email, or phone_number parameter is required" if start_params[:username].blank?

        strategy_for(start_params[:connection]).start!(start_params)

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
