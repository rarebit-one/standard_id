module StandardId
  module CableAuthentication
    extend ActiveSupport::Concern

    included do
      identified_by :current_account
    end

    def connect
      self.current_account = find_verified_account
    end

    private

    def find_verified_account
      if verified_account = find_account_from_session_token
        verified_account
      else
        reject_unauthorized_connection
      end
    end

    def find_account_from_session_token
      session_token = cookies.encrypted[:session_token] || request.session[:session_token]
      return nil if session_token.blank?

      browser_session = StandardId::BrowserSession.eager_load(:account).by_token(session_token).first
      return nil unless browser_session&.active?

      browser_session.account
    end
  end
end
