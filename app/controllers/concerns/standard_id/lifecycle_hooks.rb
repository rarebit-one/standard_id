module StandardId
  module LifecycleHooks
    extend ActiveSupport::Concern

    private

    # Invoke the after_sign_in hook if configured.
    #
    # @param account [Object] the authenticated account
    # @param context [Hash] context about the sign-in
    #   - :connection [String] "email", "password", or "social"
    #   - :provider [String, nil] e.g. "google", "apple", or nil
    #   - :first_sign_in [Boolean] whether this is the account's first browser session
    # @return [String, nil] redirect path override, or nil for default
    # @raise [StandardId::AuthenticationDenied] to reject the sign-in
    def invoke_after_sign_in(account, context)
      hook = StandardId.config.after_sign_in
      return nil unless hook.respond_to?(:call)

      context = context.merge(first_sign_in: first_sign_in?(account))
      hook.call(account, request, context)
    end

    # Invoke the after_account_created hook if configured.
    #
    # @param account [Object] the newly created account
    # @param context [Hash] context about the creation
    #   - :mechanism [String] "passwordless", "social", or "signup"
    #   - :provider [String, nil] e.g. "google", "apple", or nil
    # @return [void]
    def invoke_after_account_created(account, context)
      hook = StandardId.config.after_account_created
      return unless hook.respond_to?(:call)

      hook.call(account, request, context)
    end

    # Determine if this is the account's first browser session.
    # A count of 1 means the session just created is the only one.
    def first_sign_in?(account)
      account.sessions.where(type: "StandardId::BrowserSession").count <= 1
    end

    # Handle AuthenticationDenied by revoking the session and redirecting to login.
    #
    # @param error [StandardId::AuthenticationDenied] the denial error
    def handle_authentication_denied(error)
      session_manager.revoke_current_session!
      message = error.message
      # When raised without arguments, StandardError#message returns the class name
      message = "Sign-in was denied" if message.blank? || message == error.class.name
      redirect_to StandardId::WebEngine.routes.url_helpers.login_path, alert: message
    end
  end
end
