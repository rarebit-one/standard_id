module StandardId
  module ApiAuthentication
    extend ActiveSupport::Concern

    private

    def current_account
      api_session_manager.current_account
    end

    def authenticated?
      current_account.present?
    end

    def verify_access_token!
      api_authentication_guard.require_session!(api_session_manager)
    end

    def current_session
      api_session_manager.load_current_session
    end

    def create_device_session(account, device_id: nil, device_agent: nil)
      api_token_manager.create_device_session(account, device_id:, device_agent:)
    end

    def create_service_session(account, service_name:, service_version:, owner: nil, metadata: {})
      api_token_manager.create_service_session(
        account,
        service_name:,
        service_version:,
        owner:,
        metadata:
      )
    end

    def revoke_current_session!
      api_session_manager.revoke_current_session!
    end

    def api_session_manager
      @api_session_manager ||= StandardId::Api::SessionManager.new(request, api_token_manager)
    end

    def api_token_manager
      @api_token_manager ||= StandardId::Api::TokenManager.new(request)
    end

    def api_authentication_guard
      @api_authentication_guard ||= StandardId::Api::AuthenticationGuard.new
    end
  end
end
