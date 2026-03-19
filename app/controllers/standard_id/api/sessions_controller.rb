module StandardId
  module Api
    class SessionsController < BaseController
      authenticated_controller

      skip_before_action :validate_content_type!

      def index
        verify_access_token!

        sessions = current_account.sessions.active.order(created_at: :desc)

        render json: sessions.map { |session| serialize_session(session) }
      end

      def destroy
        verify_access_token!

        session = current_account.sessions.find_by(id: params[:id])

        unless session
          render json: { error: "not_found", error_description: "Session not found" }, status: :not_found
          return
        end

        session.revoke!(reason: "api_revocation")
        head :no_content
      end

      private

      def serialize_session(session)
        {
          id: session.id,
          type: session.type&.demodulize,
          created_at: session.created_at.iso8601,
          last_refreshed_at: session.respond_to?(:last_refreshed_at) ? session.last_refreshed_at&.iso8601 : nil,
          ip_address: session.respond_to?(:ip_address) ? session.ip_address : nil,
          user_agent: session.respond_to?(:device_agent) ? session.device_agent : nil,
          current: current_session_match?(session)
        }.compact
      end

      def current_session_match?(session)
        return false unless current_session

        current_session.respond_to?(:sub) && session.account_id.to_s == current_session.sub.to_s
      end
    end
  end
end
