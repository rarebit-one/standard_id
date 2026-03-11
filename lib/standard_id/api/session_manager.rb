module StandardId
  module Api
    class SessionManager
      def initialize(token_manager, request:)
        @token_manager = token_manager
        @request = request
      end

      def current_session
        @current_session ||= load_current_session
      end

      def current_account
        return unless current_session
        @current_account ||= load_current_account
      end

      def revoke_current_session!
        clear_session!
      end

      def clear_session!
        @current_session = nil
        @current_account = nil
      end

      private

      def load_current_account
        scope = StandardId.account_class
        scope = StandardId.config.account_scope.call(scope) if StandardId.config.account_scope
        scope.find_by(id: current_session.account_id)&.tap { |a| a.strict_loading!(false) }
      end

      def load_current_session
        return @current_session if @current_session.present?

        jwt_session = @token_manager.verify_jwt_token
        return unless jwt_session&.active?

        @current_session = jwt_session
      end
    end
  end
end
