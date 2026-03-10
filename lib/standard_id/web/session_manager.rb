module StandardId
  module Web
    class SessionManager
      attr_reader :token_manager, :request, :session, :cookies

      def initialize(token_manager, request:, session:, cookies:)
        @token_manager = token_manager
        @request = request
        @session = session
        @cookies = cookies
      end

      def current_session
        Current.session ||= load_current_session
      end

      def current_account
        Current.account ||= load_current_account
      end

      def sign_in_account(account)
        emit_session_creating(account, "browser")
        token_manager.create_browser_session(account).tap do |browser_session|
          # Store in both session and encrypted cookie for backward compatibility
          # Action Cable will use the encrypted cookie
          session[:session_token] = browser_session.token
          cookies.encrypted[:session_token] = browser_session.token
          Current.session = browser_session
          emit_session_created(browser_session, account, "browser")
        end
      end

      def revoke_current_session!
        current_session&.revoke!
        clear_session!
      end

      def set_remember_cookie(password_credential)
        cookies[:remember_token] = token_manager.create_remember_token(password_credential)
      end

      def clear_session!
        # TODO: make token key names configurable
        session.delete(:session_token)
        cookies.encrypted[:session_token] = nil
        cookies.delete(:remember_token)

        Current.session = nil
      end

      private

      def load_current_account
        account_id = current_session&.account_id
        return unless account_id

        scope = StandardId.account_class
        scope = StandardId.config.account_scope.call(scope) if StandardId.config.account_scope
        scope.find_by(id: account_id)&.tap { |a| a.strict_loading!(false) }
      end

      def load_current_session
        Current.session ||= load_session_from_session_token
        Current.session ||= load_session_from_remember_token

        if Current.session.present?
          if Current.session.expired?
            emit_session_expired(Current.session)
            clear_session!
          elsif Current.session.revoked?
            clear_session!
          end
        else
          clear_session!
        end

        Current.session
      end

      def load_session_from_session_token
        # Try encrypted cookie first (for Action Cable), then fall back to session (for backward compatibility)
        session_token = cookies.encrypted[:session_token] || session[:session_token]
        StandardId::BrowserSession.eager_load(:account).by_token(session_token).first
      end

      def load_session_from_remember_token
        password_credential = StandardId::PasswordCredential.find_by_token_for(:remember_me, cookies[:remember_token])
        return if password_credential.blank?

        token_manager.create_browser_session(password_credential.account, remember_me: true).tap do |browser_session|
          # Store in both session and encrypted cookie for backward compatibility
          session[:session_token] = browser_session.token
          cookies.encrypted[:session_token] = browser_session.token
          cookies[:remember_token] = token_manager.create_remember_token(password_credential)
        end
      end

      def emit_session_creating(account, session_type)
        StandardId::Events.publish(
          StandardId::Events::SESSION_CREATING,
          account: account,
          session_type: session_type
        )
      end

      def emit_session_created(browser_session, account, session_type)
        StandardId::Events.publish(
          StandardId::Events::SESSION_CREATED,
          session: browser_session,
          account: account,
          session_type: session_type,
          token_issued: true
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
