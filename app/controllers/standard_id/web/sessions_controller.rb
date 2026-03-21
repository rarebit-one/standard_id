module StandardId
  module Web
    class SessionsController < BaseController
      authenticated_controller
      requires_web_mechanism :sessions_management

      def index
        @sessions = current_account.sessions.active.order(created_at: :desc)
        @current_session = current_session
      end

      def destroy
        session = current_account.sessions.find(params[:id])

        if session == current_session
          # If revoking current session, sign out and redirect
          revoke_current_session!
          redirect_to "/", notice: "Session revoked. You have been signed out."
        else
          # Revoke other session
          session.revoke!
          redirect_to sessions_path, notice: "Session revoked successfully"
        end
      rescue ActiveRecord::RecordNotFound
        redirect_to sessions_path, alert: "Session not found"
      end
    end
  end
end
