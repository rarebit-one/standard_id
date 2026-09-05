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

      # Both readers memoise their answer for the rest of the request — including
      # a nil answer. `Current.session ||= …` never did: an anonymous visitor has
      # no session, so every `current_account` call (shared props, before_actions,
      # locale selection, nav helpers — five or six per page) re-ran the lookup.
      # On one consumer's marketing homepage that was ~6 session-table queries
      # per anonymous request, the app's single largest query by total time
      # (fundbright/delivery-ops#598).
      def current_session
        return Current.session if Current.session_resolved

        Current.session_resolved = true
        load_current_session
      end

      def current_account
        return Current.account if Current.account_resolved

        Current.account_resolved = true
        Current.account = load_current_account
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
          # Sign-in supersedes whatever this request already resolved: a guard
          # or shared prop that asked `current_account` before the sign-in
          # action ran memoised nil, and that memo must not outlive the sign-in.
          # The session is known here, so memoise it; the account is NOT
          # assigned directly — the memo is reset so the next `current_account`
          # re-derives it through load_current_account, which applies
          # `config.account_scope` and `strict_loading!(false)` exactly as an
          # ordinary authenticated request would (review of #327).
          Current.session = browser_session
          Current.session_resolved = true
          Current.account = nil
          Current.account_resolved = false
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
        #
        # Only touch the Rails session when it is already loaded. Reading or
        # deleting a key on an unloaded Rack session loads it, and Rack commits
        # every loaded session on the way out — so on an anonymous request this
        # used to write a brand-new empty session to the store and stamp a
        # session cookie on the response, which is what stops any CDN from
        # caching a public page. If the session was never loaded there is nothing
        # in it to clear.
        if rails_session_loaded?
          session.delete(:session_token)
          session.delete(:standard_id_scopes)
        end
        # Delete the cookie outright. Assigning `cookies.encrypted[:session_token] = nil`
        # writes a fresh encrypted blob through the jar's default options (no httponly)
        # on every unauthenticated request, leaving a confusing non-HttpOnly
        # `session_token` cookie that carries no real token. `cookies.delete` removes it
        # cleanly — the token-bearing write (write_session_cookie) keeps httponly: true.
        cookies.delete(:session_token)
        cookies.delete(:remember_token)

        Current.session = nil
        Current.account = nil
        Current.session_resolved = true
        Current.account_resolved = true
      end

      private

      # A Rack session reports `loaded?`; the plain Hash the specs (and some
      # hosts' test doubles) hand in does not, and a Hash is always "loaded".
      def rails_session_loaded?
        !session.respond_to?(:loaded?) || session.loaded?
      end

      # Whether the request carries the host app's Rails session cookie at all.
      # Reading `session[...]` when it does not would make Rack allocate and
      # then persist an empty session (see clear_session!). Without a request
      # that can answer, assume it does — the old behaviour.
      def rails_session_cookie_present?
        return true unless request.respond_to?(:session_options) && request.respond_to?(:cookies)

        key = request.session_options[:key]
        return true if key.blank?

        request.cookies.key?(key.to_s)
      end

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
          # Nothing identified a session. Clear stale state only when there is
          # some — a bare anonymous GET has no cookies to delete and no session
          # to touch, and touching it is what makes the response uncacheable.
          clear_session! if stale_session_state?
        end

        Current.session
      end

      def stale_session_state?
        cookies.encrypted[:session_token].present? || cookies[:session_token].present? || cookies[:remember_token].present? ||
          (rails_session_loaded? && (session[:session_token].present? || session[:standard_id_scopes].present?))
      end

      def load_session_from_session_token
        # Try encrypted cookie first (for Action Cable), then fall back to session (for backward compatibility)
        session_token = cookies.encrypted[:session_token]
        session_token ||= session[:session_token] if rails_session_loaded? || rails_session_cookie_present?
        return if session_token.blank?

        StandardId::BrowserSession.eager_load(:account).by_token(session_token).first
      end

      def load_session_from_remember_token
        return if cookies[:remember_token].blank?

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
