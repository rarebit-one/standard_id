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
          session: browser_session,
          account: resolve_account(browser_session)
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

      # SESSION_VALIDATING is the only one of the three emitters that runs
      # BEFORE the blank/expired/revoked checks, so it cannot borrow the
      # assumptions its siblings rely on:
      #
      #   * the session may be nil (the blank? check has not run yet), so a
      #     bare `browser_session.account` would NoMethodError; and
      #   * it also fires for sessions the host app installed into
      #     `Current.session` itself, which — unlike SessionManager's
      #     `eager_load(:account)` path — carries no loaded :account
      #     association. Several consumers run `strict_loading_by_default`
      #     (jumpdrive-web, luminality-web), where a lazy `record.account`
      #     raises StrictLoadingViolationError. Since this emitter is on the
      #     path of EVERY authenticated request, that would turn an inert
      #     guard into a 500.
      #
      # So: read the association only when it is already loaded, and otherwise
      # fall back to the same single indexed lookup Api::AuthenticationGuard's
      # resolve_account uses. Neither branch can raise under strict loading.
      def resolve_account(browser_session)
        return if browser_session.blank?

        if browser_session.respond_to?(:association) && browser_session.association(:account).loaded?
          return browser_session.account
        end

        account_id = browser_session.account_id if browser_session.respond_to?(:account_id)
        return if account_id.blank?

        StandardId.account_class.find_by(id: account_id)
      end
    end
  end
end
