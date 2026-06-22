module StandardId
  # Public concern providing authentication lifecycle hook invocations.
  #
  # Include this in host app controllers that implement custom authentication
  # flows but want to participate in StandardId's hook system. The hooks are
  # configured via `StandardId.config.before_sign_in`, `after_sign_in`, and
  # `after_account_created` callbacks.
  #
  # This is the same concern used internally by the WebEngine's built-in
  # controllers -- there is no separate "internal" version.
  #
  # Requires the including controller to include `StandardId::WebAuthentication`
  # (for `session_manager` and `request` access).
  #
  # @example Usage in a host app controller
  #   class Auth::SessionsController < ApplicationController
  #     include StandardId::WebAuthentication
  #     include StandardId::LifecycleHooks
  #
  #     def create
  #       account = authenticate_somehow(params)
  #       invoke_before_sign_in(account, { mechanism: "custom", provider: nil })
  #       session_manager.sign_in_account(account)
  #       redirect_override = invoke_after_sign_in(account, { mechanism: "custom", provider: nil })
  #       redirect_to redirect_override || root_path
  #     rescue StandardId::AuthenticationDenied => e
  #       handle_authentication_denied(e)
  #     end
  #   end
  module LifecycleHooks
    extend ActiveSupport::Concern

    # Default profile resolver when StandardId.config.profile_resolver is nil.
    DEFAULT_PROFILE_RESOLVER = ->(acct, pt) { acct.profiles.exists?(profileable_type: pt) }

    # Default scope resolver when StandardId.config.scope_resolver is nil.
    # Preserves the historical behaviour of reading :scope from route defaults.
    DEFAULT_SCOPE_RESOLVER = ->(request:, session:) { request.path_parameters[:scope]&.to_sym }

    private

    # Invoke the before_sign_in hook if configured.
    # Called after credential verification, BEFORE session creation.
    #
    # When a scope is active (via route defaults), the built-in profile
    # validation runs BEFORE the app's custom hook. If the account lacks
    # the required profile, AuthenticationDenied is raised immediately.
    #
    # @param account [Object] the authenticated account
    # @param context [Hash] context about the sign-in
    #   - :mechanism [String] "password", "passwordless", or "social"
    #   - :provider [String, nil] e.g. "google", "apple", or nil
    #   - :first_sign_in [Boolean] whether this is the account's first browser session
    #   - :scope [Symbol, nil] scope name when scoped authentication is active
    #   - :profile_type [String, nil] first configured profile type for the scope (back-compat)
    #   - :profile_types [Array<String>, nil] all configured profile types for the scope
    #   - :after_sign_in_path [String, nil] default redirect path for the scope
    # @return [void]
    # @raise [StandardId::AuthenticationDenied] when profile check fails or hook returns { error: "..." }
    def invoke_before_sign_in(account, context)
      scope_config = current_scope_config
      if scope_config
        context = context.merge(scope_context(scope_config))

        # Built-in profile check and/or authorizer — runs before the app's custom hook.
        # A scope may configure :authorizer without :profile_types (e.g. policy-only
        # gates), so we must still run validate_scope_profile! in that case —
        # otherwise the authorizer would be silently skipped and every sign-in
        # granted regardless of its decision.
        if scope_config.requires_profile? || scope_config.authorizer?
          validate_scope_profile!(account, scope_config)
        end
      end

      context = context.merge(first_sign_in: first_sign_in?(account, session_created: false))

      hook = StandardId.config.before_sign_in
      return unless hook.respond_to?(:call)

      result = hook.call(account, request, context)

      if result.is_a?(Hash) && result[:error].present?
        raise StandardId::AuthenticationDenied, result[:error]
      end
    end

    # Invoke the after_sign_in hook if configured.
    #
    # When a scope is active, scope context is merged into the context hash.
    # If the hook does not return a custom redirect path, the scope's
    # after_sign_in_path is used as the default redirect.
    #
    # @param account [Object] the authenticated account
    # @param context [Hash] context about the sign-in
    #   - :mechanism [String] "password", "passwordless", or "social"
    #   - :provider [String, nil] e.g. "google", "apple", or nil
    #   - :first_sign_in [Boolean] whether this is the account's first browser session
    #   - :session [StandardId::Session] the session that was just created
    #   - :scope [Symbol, nil] scope name when scoped authentication is active
    #   - :profile_type [String, nil] first configured profile type for the scope (back-compat)
    #   - :profile_types [Array<String>, nil] all configured profile types for the scope
    #   - :after_sign_in_path [String, nil] default redirect path for the scope
    #   - :redirect_uri [String, nil] caller-supplied destination (from the form
    #     param for password/signup, from the OAuth state cookie for social).
    #     Hooks that always return a default path should return nil when this is
    #     present so the originator's URL wins — otherwise upstream OAuth/SSO
    #     flows that send users to /login?redirect_uri=... will land on the
    #     hook's default page instead of completing the handshake.
    # @return [String, nil] redirect path override, or nil for default
    # @raise [StandardId::AuthenticationDenied] to reject the sign-in
    def invoke_after_sign_in(account, context)
      scope_config = current_scope_config
      context = context.merge(scope_context(scope_config)) if scope_config

      hook = StandardId.config.after_sign_in
      context = context.merge(
        first_sign_in: first_sign_in?(account, session_created: true),
        session: session_manager.current_session
      )

      if hook.respond_to?(:call)
        result = hook.call(account, request, context)
        # If hook returned a redirect path, use it; otherwise fall back to scope path
        return result if result.present?
      end

      # When the caller supplied a :redirect_uri and the hook returned nil, treat that
      # as the documented "defer to originator" signal — do NOT shadow it with the
      # scope's after_sign_in_path (which would silently break OAuth/SSO handshakes
      # for any host that configures a scope default).
      return nil if context[:redirect_uri].present?

      # When no hook override, use the scope's after_sign_in_path if present
      scope_config&.after_sign_in_path
    end

    # Invoke the after_account_created hook if configured.
    #
    # @param account [Object] the newly created account
    # @param context [Hash] context about the creation
    #   - :mechanism [String] "passwordless", "social", or "signup"
    #   - :provider [String, nil] e.g. "google", "apple", or nil
    #   - :scope [Symbol, nil] scope name when scoped authentication is active
    #   - :profile_type [String, nil] first configured profile type for the scope (back-compat)
    #   - :profile_types [Array<String>, nil] all configured profile types for the scope
    #   - :after_sign_in_path [String, nil] default redirect path for the scope
    # @return [void]
    def invoke_after_account_created(account, context)
      scope_config = current_scope_config
      context = context.merge(scope_context(scope_config)) if scope_config

      hook = StandardId.config.after_account_created
      return unless hook.respond_to?(:call)

      hook.call(account, request, context)
    end

    # Determine if this is the account's first browser session.
    # Uses `exists?` (which compiles to `SELECT 1 ... LIMIT 1`) instead of
    # `count` — we only care whether *any other* active browser session is
    # present, not the exact number. This short-circuits as soon as a row is
    # found, so it's dramatically cheaper on accounts with many sessions.
    #
    # When called before session creation (before_sign_in), "first" means no
    # active browser session exists at all.
    # When called after session creation (after_sign_in), the just-created
    # session counts as one, so "first" means no OTHER active browser session
    # exists — i.e. exclude the current session before checking existence.
    #
    # Invariant: when `session_created: true`, `session_manager.current_session`
    # is always set — invoke_after_sign_in runs immediately after
    # session_manager.sign_in_account, which populates current_session. The
    # nil guard below is defensive only; it would behave differently from the
    # old `count <= 1` path (new: false, old: true) if that invariant were
    # ever violated, but today no call site can reach it.
    def first_sign_in?(account, session_created: true)
      scope = account.sessions.where(type: "StandardId::BrowserSession").active
      scope = scope.where.not(id: session_manager.current_session.id) if session_created && session_manager.current_session
      !scope.exists?
    end

    # Handle AuthenticationDenied by revoking the session and redirecting to login.
    # If the account was just created, clean it up to avoid orphaned records.
    #
    # @note By default this redirects to the WebEngine's login_path. Host app
    #   controllers that include LifecycleHooks without mounting the WebEngine
    #   should override this method to redirect to their own login page. When the
    #   WebEngine route is unavailable, falls back to `StandardId.config.login_url`
    #   or `"/"`.
    # @param error [StandardId::AuthenticationDenied] the denial error
    # @param account [Object, nil] the account to clean up if newly created
    # @param newly_created [Boolean] whether the account was created during this request
    def handle_authentication_denied(error, account: nil, newly_created: false)
      session_manager.revoke_current_session! if session_manager.current_session.present?
      destroy_newly_created_account(account) if newly_created
      message = error.message
      # When raised without arguments, StandardError#message returns the class name
      message = "Sign-in was denied" if message.blank? || message == error.class.name
      login_path = begin
        # Engine `_path` helpers are mount-relative and redirect_to won't prepend
        # the mount's SCRIPT_NAME (no-op at root), so a non-root mount would 404.
        "#{request.script_name}#{StandardId::WebEngine.routes.url_helpers.login_path}"
      rescue NameError, NoMethodError, ActionController::UrlGenerationError
        StandardId.config.login_url || "/"
      end
      redirect_to login_path, alert: message
    end

    # Destroy a newly created account and all its dependents.
    # Used when after_sign_in rejects a just-created account to avoid orphans.
    def destroy_newly_created_account(account)
      return unless account&.persisted?

      ActiveRecord::Base.transaction do
        account.sessions.destroy_all
        account.identifiers.each { |i| i.credentials.destroy_all }
        account.identifiers.destroy_all
        account.destroy
      end
    end

    # Resolve the active scope name for the current request.
    # Delegates to the app-configured :scope_resolver callable so apps can source
    # the scope from subdomains, session state, or custom path params without
    # overriding this concern.
    # Memoized per request.
    def current_scope_name
      return @current_scope_name if defined?(@current_scope_name)
      resolver = StandardId.config.scope_resolver
      resolver = DEFAULT_SCOPE_RESOLVER unless resolver.respond_to?(:call)
      session = session_manager.respond_to?(:current_session) ? session_manager.current_session : nil
      @current_scope_name = resolver.call(request: request, session: session)
    end

    # Look up the scope config for the current request.
    # Returns nil when no scope is active, preserving backward compatibility.
    # Memoized per request to avoid redundant ScopeConfig allocations.
    def current_scope_config
      return @current_scope_config if defined?(@current_scope_config)
      @current_scope_config = StandardId.scope_for(current_scope_name)
    end

    # Validate that the account has a profile matching one of the scope's configured
    # profile_types, then (when configured) run the scope's custom :authorizer callable.
    #
    # Raises StandardId::AuthenticationDenied using the scope's no_profile_message when:
    #   - no profile of any configured type exists, or
    #   - the :authorizer returns a falsey value.
    def validate_scope_profile!(account, scope_config)
      resolver = StandardId.config.profile_resolver || DEFAULT_PROFILE_RESOLVER
      matched_type = nil

      if scope_config.requires_profile?
        matched_type = scope_config.profile_types.find { |type| resolver.call(account, type) }

        unless matched_type
          raise StandardId::AuthenticationDenied, scope_config.no_profile_message
        end
      end

      return unless scope_config.authorizer?

      profile = matched_type ? resolve_profile_for_authorizer(account, matched_type) : nil
      result = scope_config.authorizer.call(
        account: account,
        profile: profile,
        scope: scope_config
      )

      unless result
        raise StandardId::AuthenticationDenied, scope_config.no_profile_message
      end
    end

    # Best-effort lookup of the matched profile record to pass into the :authorizer.
    # Returns nil when the account does not expose a :profiles association of the
    # expected shape — authorizers that need richer context can re-query from the
    # account keyword arg.
    #
    # Rescue is narrowed to the structural cases we actually want to tolerate
    # (missing methods / wrong types on a shape-mismatched association). DB-level
    # errors are intentionally allowed to propagate so a transient outage isn't
    # silently converted into "no profile found" and a denied sign-in.
    def resolve_profile_for_authorizer(account, profile_type)
      return nil unless account.respond_to?(:profiles)
      relation = account.profiles
      return nil unless relation.respond_to?(:find_by)
      relation.find_by(profileable_type: profile_type)
    rescue NoMethodError, TypeError
      nil
    end

    # Build the hash of scope fields merged into lifecycle hook context.
    # Includes the legacy :profile_type (singular) alongside :profile_types (plural)
    # so existing hooks keep reading the same key.
    def scope_context(scope_config)
      {
        scope: scope_config.name,
        profile_type: scope_config.profile_type,
        profile_types: scope_config.profile_types,
        after_sign_in_path: scope_config.after_sign_in_path
      }
    end
  end
end
