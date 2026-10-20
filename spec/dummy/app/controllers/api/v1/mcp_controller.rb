module Api
  module V1
    # Exercises StandardId::ResourceServer end to end (spec/requests/standard_id/resource_server_spec.rb).
    class McpController < ActionController::API
      include StandardId::ResourceServer

      protected_resource "mcp", scopes: %w[mcp]

      def show
        render json: { ok: true, account_id: current_account&.id, aud: current_session.aud }
      end
    end
  end
end
