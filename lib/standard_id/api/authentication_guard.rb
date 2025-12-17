module StandardId
  module Api
    class AuthenticationGuard
      def require_session!(session_manager, request: nil)
        api_session = session_manager.current_session
        emit_session_validating(api_session, request)

        if api_session.blank?
          raise StandardId::NotAuthenticatedError, "Invalid or missing access token"
        elsif api_session.respond_to?(:expired?) && api_session.expired?
          emit_session_expired(api_session)
          raise StandardId::ExpiredSessionError, "Session has expired"
        elsif api_session.respond_to?(:revoked?) && api_session.revoked?
          session_manager.clear_session!
          raise StandardId::RevokedSessionError, "Session has been revoked"
        end

        emit_session_validated(api_session)
        api_session
      end

      def require_scopes!(session_manager, *required_scopes)
        api_session = require_session!(session_manager)

        expected_scopes = normalize_scopes(required_scopes)
        return api_session if expected_scopes.empty?

        token_scopes = extract_session_scopes(api_session)
        unless (token_scopes & expected_scopes).any?
          raise StandardId::InvalidScopeError,
            "Access token missing required scope. Requires one of: #{expected_scopes.join(', ')}"
        end

        api_session
      end

      private

      def extract_session_scopes(api_session)
        api_session&.scopes || []
      end

      def normalize_scopes(required_scopes)
        return [] if required_scopes.nil?

        case required_scopes
        when String
          [required_scopes]
        when Symbol
          [required_scopes.to_s]
        when Array
          required_scopes.flat_map { |value| normalize_scopes(value) }.uniq
        else
          raise ArgumentError, "Scopes must be provided as a String, Symbol, or Array"
        end
      end

      def emit_session_validating(api_session, request)
        StandardId::Events.publish(
          StandardId::Events::SESSION_VALIDATING,
          session: api_session
        )
      end

      def emit_session_validated(api_session)
        account = if api_session.respond_to?(:account)
                    api_session.account
        elsif api_session.respond_to?(:account_id)
                    StandardId.account_class.find_by(id: api_session.account_id)
        end

        StandardId::Events.publish(
          StandardId::Events::SESSION_VALIDATED,
          session: api_session,
          account: account
        )
      end

      def emit_session_expired(api_session)
        account = if api_session.respond_to?(:account)
                    api_session.account
        elsif api_session.respond_to?(:account_id)
                    StandardId.account_class.find_by(id: api_session.account_id)
        end

        StandardId::Events.publish(
          StandardId::Events::SESSION_EXPIRED,
          session: api_session,
          account: account,
          expired_at: api_session.respond_to?(:expires_at) ? api_session.expires_at : nil
        )
      end
    end
  end
end
