module StandardId
  module Web
    class SessionManager
      attr_reader :token_manager, :request, :session, :cookies

      def initialize(token_manager, request:, session:, cookies:, reset_session: nil)
        @token_manager = token_manager
        @request = request
        @session = session
        @cookies = cookies
        @reset_session = reset_session
      end

      def current_session
        Current.session ||= load_current_session
      end

      def current_account
        Current.account ||= load_current_account
      end

      def sign_in_account(account, scope_name: nil)
        emit_session_creating(account, "browser")

        # Prevent session fixation by resetting the Rails session before
        # creating an authenticated session (Rails Security Guide §2.5).
        # Preserve return_to URL across the reset so post-login redirect works.
        return_to = session[:return_to_after_authenticating]
        existing_scopes = session[:standard_id_scopes]
        @reset_session&.call
        session[:return_to_after_authenticating] = return_to if return_to
        session[:standard_id_scopes] = existing_scopes if existing_scopes

        token_manager.create_browser_session(account).tap do |browser_session|
          # Store in both session and encrypted cookie for backward compatibility
          # Action Cable will use the encrypted cookie
          session[:session_token] = browser_session.token
          write_session_cookie(browser_session)
          if scope_name
            scopes = Array(session[:standard_id_scopes])
            scopes << scope_name.to_s unless scopes.include?(scope_name.to_s)
            session[:standard_id_scopes] = scopes
          end
          Current.session = browser_session
          emit_session_created(browser_session, account, "browser")
        end
      end

      def current_scope_names
        Array(session[:standard_id_scopes])
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
        session.delete(:standard_id_scopes)
        cookies.encrypted[:session_token] = nil
        cookies.delete(:remember_token)

        Current.session = nil
      end

      private

      # Persist the session token in an encrypted cookie whose lifetime matches
      # the DB session's expires_at, so an authenticated session survives a full
      # browser restart (a bare session cookie would be cleared on browser close,
      # logging the user out well before the BrowserSession actually expires).
      # httponly/secure/same_site harden the cookie; httponly does not affect
      # Action Cable, which reads the cookie server-side.
      def write_session_cookie(browser_session)
        cookies.encrypted[:session_token] = {
          value:     browser_session.token,
          expires:   browser_session.expires_at,
          httponly:  true,
          secure:    request.ssl?,
          same_site: :lax
        }
      end

      def load_current_account
        if StandardId.config.account_scope
          account_id = current_session&.account_id
          return unless account_id

          scope = StandardId.account_class
          scope = StandardId.config.account_scope.call(scope)
          scope.find_by(id: account_id)&.tap { |a| a.strict_loading!(false) }
        else
          current_session&.account&.tap { |a| a.strict_loading!(false) }
        end
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

        # Prevent session fixation on returning-user remember-me flow.
        # Note: standard_id_scopes are intentionally NOT preserved here —
        # remember-me re-auth is a fresh session context where scopes
        # must be re-acquired through explicit scoped sign-in.
        @reset_session&.call

        token_manager.create_browser_session(password_credential.account, remember_me: true).tap do |browser_session|
          # Store in both session and encrypted cookie for backward compatibility
          session[:session_token] = browser_session.token
          write_session_cookie(browser_session)
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
