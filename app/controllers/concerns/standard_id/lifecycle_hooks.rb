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
      account.sessions.where(type: "StandardId::BrowserSession").active.count <= 1
    end

    # Handle AuthenticationDenied by revoking the session and redirecting to login.
    # If the account was just created, clean it up to avoid orphaned records.
    #
    # @param error [StandardId::AuthenticationDenied] the denial error
    # @param account [Object, nil] the account to clean up if newly created
    # @param newly_created [Boolean] whether the account was created during this request
    def handle_authentication_denied(error, account: nil, newly_created: false)
      session_manager.revoke_current_session!
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
  end
end
