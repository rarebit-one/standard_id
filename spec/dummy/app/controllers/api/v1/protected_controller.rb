module Api
  module V1
    class ProtectedController < ApplicationController
      include StandardId::Api::AuthenticationGuard

      before_action :require_api_authentication!

      def show
        render json: {
          message: "Successfully accessed protected endpoint",
          authenticated_client: current_client&.id,
          scopes: current_token_scopes,
          timestamp: Time.current.iso8601
        }
      end
    end
  end
end
