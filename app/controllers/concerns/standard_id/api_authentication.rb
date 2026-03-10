module StandardId
  module ApiAuthentication
    extend ActiveSupport::Concern

    included do
      if StandardId.config.alias_current_user
        define_method(:current_user) { current_account }
      end
    end

    delegate :current_session, :current_account, :revoke_current_session!, to: :session_manager

    private

    def authenticated?
      current_account.present?
    end

    def verify_access_token!
      authentication_guard.require_session!(session_manager)
    end

    def require_scopes!(*required_scopes)
      authentication_guard.require_scopes!(session_manager, *required_scopes)
    end

    def session_manager
      @session_manager ||= StandardId::Api::SessionManager.new(token_manager, request:)
    end

    def token_manager
      @token_manager ||= StandardId::Api::TokenManager.new(request)
    end

    def authentication_guard
      @authentication_guard ||= StandardId::Api::AuthenticationGuard.new
    end
  end
end
