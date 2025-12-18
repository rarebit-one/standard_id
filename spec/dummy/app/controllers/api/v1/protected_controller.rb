module Api
  module V1
    class ProtectedController < ApplicationController
      include StandardId::ApiAuthentication

      before_action :verify_access_token!

      def show
        render json: {
          message: "Successfully accessed protected endpoint",
          authenticated_account: current_account&.id,
          session_id: current_session&.id,
          timestamp: Time.current.iso8601
        }
      end
    end
  end
end
