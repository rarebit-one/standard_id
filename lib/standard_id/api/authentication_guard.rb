module StandardId
  module Api
    class AuthenticationGuard
      def require_session!(session_manager)
        api_session = session_manager.current_session

        if api_session.blank?
          raise StandardId::NotAuthenticatedError, "Invalid or missing access token"
        elsif api_session.respond_to?(:expired?) && api_session.expired?
          raise StandardId::ExpiredSessionError, "Session has expired"
        elsif api_session.respond_to?(:revoked?) && api_session.revoked?
          session_manager.clear_session!
          raise StandardId::RevokedSessionError, "Session has been revoked"
        end

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
    end
  end
end
