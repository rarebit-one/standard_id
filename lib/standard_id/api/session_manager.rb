module StandardId
  module Api
    class SessionManager
      def initialize(request, api_token_manager)
        @request = request
        @api_token_manager = api_token_manager
      end

      def load_current_session
        return @current_session if @current_session.present?

        token = @api_token_manager.extract_bearer_token
        return unless token

        session = StandardId::Session.api_compatible.by_token(token).first

        return unless session&.active?

        session.touch(:last_refreshed_at) if session.is_a?(StandardId::DeviceSession)

        @current_session = session
      end

      def current_account
        load_current_session&.account
      end

      def revoke_current_session!
        return unless @current_session

        @current_session.revoke!
        @current_session = nil
      end

      def clear_session!
        @current_session = nil
      end
    end
  end
end
