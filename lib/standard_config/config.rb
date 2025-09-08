module StandardConfig
  # Manages configuration for the StandardId engine
  #
  # Usage:
  #   StandardId.configure do |config|
  #     config.account_class_name = "User"
  #     config.cache_store = ActiveSupport::Cache::MemoryStore.new
  #     config.logger = Rails.logger
  #     config.allowed_post_logout_redirect_uris = ["https://example.com/logout"]
  #   end
  class Config
    # The name of the Account model class as a String, e.g. "User" or "Account"
    attr_accessor :account_class_name

    # Optional cache store and logger, used by StandardId.cache_store and StandardId.logger
    attr_accessor :cache_store, :logger

    # OAuth issuer identifier for ID tokens
    attr_accessor :issuer

    # Optional login URL for redirecting unauthenticated browser requests
    # Example: "/login" or a full URL like "https://app.example.com/login"
    # If set, Authorization endpoints can redirect to this path with a redirect_uri param
    attr_accessor :login_url

    # Social login provider credentials
    attr_accessor :google_client_id, :google_client_secret
    attr_accessor :apple_client_id, :apple_client_secret, :apple_private_key, :apple_key_id, :apple_team_id

    # Passwordless authentication callbacks
    # These should be callable objects (procs/lambdas) that accept (recipient, code) parameters
    attr_accessor :passwordless_email_sender, :passwordless_sms_sender

    # Allowed post-logout redirect URIs for OIDC logout endpoint
    # If empty or nil, no redirects are allowed and the endpoint will return a JSON message
    # If provided, the post_logout_redirect_uri must exactly match one of the values in this list
    attr_accessor :allowed_post_logout_redirect_uris

    # Layout name to use for StandardId Web controllers.
    # If nil, controllers should default to "application" (host app or dummy app).
    # Examples: "application", "standard_id/web/application", "my_custom_layout"
    attr_accessor :web_layout

    def initialize
      @account_class_name = nil
      @cache_store = nil
      @logger = nil
      @issuer = nil
      @login_url = nil
      @google_client_id = nil
      @google_client_secret = nil
      @apple_client_id = nil
      @apple_client_secret = nil
      @apple_private_key = nil
      @apple_key_id = nil
      @apple_team_id = nil
      @passwordless_email_sender = nil
      @passwordless_sms_sender = nil
      @allowed_post_logout_redirect_uris = []
      @web_layout = nil
    end

    def account_class
      account_class_name.constantize
    rescue NameError
      raise NameError, "Could not find account class: #{account_class_name}. Please set a valid class name using `StandardId.configure { |c| c.account_class_name = 'YourAccountClass' }`"
    end
  end
end
