module StandardId
  module Api
    class SessionsController < BaseController
      authenticated_controller

      skip_before_action :validate_content_type!
      before_action :verify_access_token!

      def index
        sessions = current_account.sessions.active.order(created_at: :desc)

        render json: sessions.map { |session| serialize_session(session) }
      end

      def destroy
        session = current_account.sessions.find_by(id: params[:id])

        unless session
          render json: { error: "not_found", error_description: "Session not found" }, status: :not_found
          return
        end

        session.revoke!(reason: "api_revocation")
        head :no_content
      end

      private

      # All Session subclasses live on the same STI table and therefore
      # always respond to these columns — the prior `respond_to?` guards
      # were defensive overhead that allocated per record. Direct access
      # is both cheaper and clearer.
      def serialize_session(session)
        {
          id: session.id,
          type: session.type&.demodulize,
          created_at: session.created_at.iso8601,
          last_refreshed_at: session.last_refreshed_at&.iso8601,
          ip_address: session.ip_address,
          # user_agent is the API-facing name for the device_agent model attribute
          user_agent: session.device_agent
        }.compact
      end
    end
  end
end
