module StandardId
  module Api
    class AuthenticationGuard
      def require_session!(api_session_manager)
        session = api_session_manager.load_current_session

        if session.blank?
          raise StandardId::NotAuthenticatedError, "Invalid or missing access token"
        elsif session.expired?
          api_session_manager.clear_session!
          raise StandardId::ExpiredSessionError, "Session has expired"
        elsif session.revoked?
          api_session_manager.clear_session!
          raise StandardId::RevokedSessionError, "Session has been revoked"
        end

        session
      end
    end
  end
end
