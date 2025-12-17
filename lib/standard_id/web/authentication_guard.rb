module StandardId
  module Web
    class AuthenticationGuard
      def require_session!(session_manager, session:, request:)
        session[:return_to_after_authenticating] = request.url

        browser_session = session_manager.current_session
        emit_session_validating(browser_session, request)

        if browser_session.blank?
          raise StandardId::NotAuthenticatedError
        elsif browser_session.expired?
          emit_session_expired(browser_session)
          session_manager.clear_session!
          raise StandardId::ExpiredSessionError
        elsif browser_session.revoked?
          session_manager.clear_session!
          raise StandardId::RevokedSessionError
        end

        emit_session_validated(browser_session)
        browser_session
      end

      private

      def emit_session_validating(browser_session, request)
        StandardId::Events.publish(
          StandardId::Events::SESSION_VALIDATING,
          session: browser_session
        )
      end

      def emit_session_validated(browser_session)
        StandardId::Events.publish(
          StandardId::Events::SESSION_VALIDATED,
          session: browser_session,
          account: browser_session.account
        )
      end

      def emit_session_expired(browser_session)
        StandardId::Events.publish(
          StandardId::Events::SESSION_EXPIRED,
          session: browser_session,
          account: browser_session.account,
          expired_at: browser_session.expires_at
        )
      end
    end
  end
end
