require "standard_id/version"
require "standard_id/current_attributes"
require "standard_id/engine"
require "standard_id/web_engine"
require "standard_id/api_engine"
require "standard_id/config_schema"
require "standard_id/config/schema"
require "standard_id/scope_config"
require "standard_id/errors"
require "standard_id/events"
require "standard_id/events/subscribers/base"
require "standard_id/events/subscribers/logging_subscriber"
require "standard_id/events/subscribers/account_status_subscriber"
require "standard_id/events/subscribers/account_locking_subscriber"
require "standard_id/events/subscribers/passwordless_delivery_subscriber"
require "standard_id/events/subscribers/password_reset_delivery_subscriber"
require "standard_id/account_status"
require "standard_id/account_locking"
require "standard_id/http_client"
require "standard_id/bearer_token_extraction"
require "standard_id/jwt_service"
require "standard_id/session_type_resolver"
require "standard_id/web/session_manager"
require "standard_id/web/token_manager"
require "standard_id/web/authentication_guard"
require "standard_id/api/session_manager"
require "standard_id/api/token_manager"
require "standard_id/api/authentication_guard"
require "standard_id/utils/callable_parameter_filter"
require "standard_id/oauth/audience_profile_resolver"
require "standard_id/oauth/base_request_flow"
require "standard_id/oauth/token_lifetime_resolver"
require "standard_id/oauth/oauth_session_persistence"
require "standard_id/oauth/token_grant_flow"
require "standard_id/oauth/client_credentials_flow"
require "standard_id/oauth/authorization_code_flow"
require "standard_id/oauth/password_flow"
require "standard_id/oauth/refresh_token_flow"
require "standard_id/oauth/social_flow"
require "standard_id/oauth/authorization_flow"
require "standard_id/oauth/authorization_code_authorization_flow"
require "standard_id/oauth/implicit_authorization_flow"
require "standard_id/oauth/subflows/base"
require "standard_id/oauth/subflows/traditional_code_grant"
require "standard_id/oauth/subflows/social_login_grant"
require "standard_id/oauth/passwordless_otp_flow"
require "standard_id/oauth/discovery_document"
require "standard_id/oauth/consent_payload"
require "standard_id/passwordless/base_strategy"
require "standard_id/passwordless/email_strategy"
require "standard_id/passwordless/sms_strategy"
require "standard_id/passwordless/verification_service"
require "standard_id/passwordless"
require "standard_id/otp"
require "standard_id/authorization_bypass"
require "standard_id/utils/ip_normalizer"
require "standard_id/rate_limit_store"

require "concurrent/delay"

require "standard_id/providers/base"
require "standard_id/provider_registry"

module StandardId
  CONFIG = Concurrent::Delay.new { ConfigSchema.build }

  class << self
    CACHE_STORE = Concurrent::Delay.new { config.cache_store || Rails.cache }
    LOGGER = Concurrent::Delay.new { config.logger || Rails.logger }

    def configure(&block)
      yield config if block_given?
      config
    end

    def register(scope_name, resolver_proc)
      config.register(scope_name, resolver_proc)
    end

    def config
      CONFIG.value
    end

    def cache_store
      CACHE_STORE.value
    end

    def logger
      LOGGER.value
    end

    def account_class
      config.account_class_name.constantize
    end

    def scope_for(name)
      return nil if config.scopes.blank? || name.blank?
      scope_hash = config.scopes[name.to_sym]
      return nil unless scope_hash
      ScopeConfig.new(name, scope_hash)
    end

    def skip_host_authorization(framework: nil, callback: nil)
      AuthorizationBypass.apply(framework: framework, callback: callback)
    end
  end
end
