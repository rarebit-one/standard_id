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
    #   - :profile_type [String, nil] required profile type for the scope
    #   - :after_sign_in_path [String, nil] default redirect path for the scope
    # @return [void]
    # @raise [StandardId::AuthenticationDenied] when profile check fails or hook returns { error: "..." }
    def invoke_before_sign_in(account, context)
      scope_config = current_scope_config
      if scope_config
        context = context.merge(
          scope: scope_config.name,
          profile_type: scope_config.profile_type,
          after_sign_in_path: scope_config.after_sign_in_path
        )

        # Built-in profile check — runs before the app's custom hook
        if scope_config.requires_profile?
          resolver = StandardId.config.profile_resolver || DEFAULT_PROFILE_RESOLVER
          unless resolver.call(account, scope_config.profile_type)
            raise StandardId::AuthenticationDenied, scope_config.no_profile_message
          end
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
    #   - :profile_type [String, nil] required profile type for the scope
    #   - :after_sign_in_path [String, nil] default redirect path for the scope
    # @return [String, nil] redirect path override, or nil for default
    # @raise [StandardId::AuthenticationDenied] to reject the sign-in
    def invoke_after_sign_in(account, context)
      scope_config = current_scope_config
      if scope_config
        context = context.merge(
          scope: scope_config.name,
          profile_type: scope_config.profile_type,
          after_sign_in_path: scope_config.after_sign_in_path
        )
      end

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
    #   - :profile_type [String, nil] required profile type for the scope
    #   - :after_sign_in_path [String, nil] default redirect path for the scope
    # @return [void]
    def invoke_after_account_created(account, context)
      scope_config = current_scope_config
      if scope_config
        context = context.merge(
          scope: scope_config.name,
          profile_type: scope_config.profile_type,
          after_sign_in_path: scope_config.after_sign_in_path
        )
      end

      hook = StandardId.config.after_account_created
      return unless hook.respond_to?(:call)

      hook.call(account, request, context)
    end

    # Determine if this is the account's first browser session.
    # When called before session creation (before_sign_in), count == 0 means first.
    # When called after session creation (after_sign_in), count <= 1 means first
    # (the just-created session is the only one).
    def first_sign_in?(account, session_created: true)
      active_count = account.sessions.where(type: "StandardId::BrowserSession").active.count
      session_created ? active_count <= 1 : active_count == 0
    end

    # Handle AuthenticationDenied by revoking the session and redirecting to login.
    # If the account was just created, clean it up to avoid orphaned records.
    #
    # @param error [StandardId::AuthenticationDenied] the denial error
    # @param account [Object, nil] the account to clean up if newly created
    # @param newly_created [Boolean] whether the account was created during this request
    def handle_authentication_denied(error, account: nil, newly_created: false)
      session_manager.revoke_current_session! if session_manager.current_session.present?
      destroy_newly_created_account(account) if newly_created
      message = error.message
      # When raised without arguments, StandardError#message returns the class name
      message = "Sign-in was denied" if message.blank? || message == error.class.name
      redirect_to StandardId::WebEngine.routes.url_helpers.login_path, alert: message
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

    # Look up the scope config for the current request.
    # Reads :scope from route defaults (set by scoped route constraints).
    # Returns nil when no scope is active, preserving backward compatibility.
    # Memoized per request to avoid redundant ScopeConfig allocations.
    def current_scope_config
      return @current_scope_config if defined?(@current_scope_config)
      @current_scope_config = StandardId.scope_for(request.path_parameters[:scope])
    end
  end
end
