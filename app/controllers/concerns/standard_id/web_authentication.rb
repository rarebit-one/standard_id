module StandardId
  module WebAuthentication
    extend ActiveSupport::Concern

    included do
      helper_method :current_account, :authenticated?
    end

    private

    def authenticated?
      current_account.present?
    end

    def current_account
      Current.account ||= current_browser_session&.account
    end

    def current_browser_session
      return Current.session if Current.session.present?

      Current.session ||= load_session_from_session_token
      Current.session ||= load_session_from_remember_token

      clear_session! if Current.session.blank? || Current.session.expired? || Current.session.revoked?

      Current.session
    end

    def load_session_from_session_token
      return unless session[:session_token]
      StandardId::BrowserSession.eager_load(:account).lookup_by_token(session[:session_token])
    end

    def load_session_from_remember_token
      password_credential = StandardId::PasswordCredential.find_by_token_for(:remember_me, cookies[:remember_token])
      return if password_credential.blank?

      browser_session = create_browser_session(password_credential.account, remember_me: true)
      session[:session_token] = browser_session.instance_variable_get(:@token)
      create_remember_token(password_credential)

      browser_session
    end

    def clear_session!
      # TODO: make token key names configurable
      session.delete(:session_token)
      cookies.delete(:remember_token)

      Current.session = nil
    end

    def require_browser_session!
      session[:return_to_after_authenticating] = request.url

      # Load session without clearing it first to detect specific error types
      browser_session = Current.session || load_session_from_session_token || load_session_from_remember_token

      if browser_session.blank?
        raise StandardId::NotAuthenticatedError
      elsif browser_session.expired?
        clear_session!
        raise StandardId::ExpiredSessionError
      elsif browser_session.revoked?
        clear_session!
        raise StandardId::RevokedSessionError
      end

      # Set the valid session
      Current.session = browser_session
    end

    def after_authentication_url
      # TODO: add configurable value
      session.delete(:return_to_after_authenticating) || root_url
    end

    def sign_in_account(account)
      browser_session = create_browser_session(account)
      session[:session_token] = browser_session.instance_variable_get(:@token)
      Current.session = browser_session
      browser_session
    end

    def sign_out_account
      current_browser_session&.revoke!
      clear_session!
    end

    def create_browser_session(account, remember_me: false)
      StandardId::BrowserSession.create!(
        account:,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        expires_at: remember_me ? 30.days.from_now : 24.hours.from_now # TODO: make these configurable
      )
    end

    def create_remember_token(password_credential)
      cookies[:remember_token] = {
          value: password_credential.generate_token_for(:remember_me),
          expires: password_credential.expires_at,
          httponly: true,
          secure: request.ssl?,
          same_site: :lax
        }
    end
  end
end
