module StandardId
  module Web
    class AuthenticationGuard
      def require_session!(session_manager, session, request)
        session[:return_to_after_authenticating] = request.url

        # Load session without clearing it first to detect specific error types
        browser_session = Current.session || session_manager.load_current_session

        if browser_session.blank?
          raise StandardId::NotAuthenticatedError
        elsif browser_session.expired?
          session_manager.clear_session!
          raise StandardId::ExpiredSessionError
        elsif browser_session.revoked?
          session_manager.clear_session!
          raise StandardId::RevokedSessionError
        end

        # Set the valid session
        Current.session = browser_session
      end

      def after_authentication_url(session)
        # TODO: add configurable value
        session.delete(:return_to_after_authenticating) || "/"
      end
    end
  end
end
