require "standard_id/version"
require "standard_id/current_attributes"
require "standard_id/engine"
require "standard_id/web_engine"
require "standard_id/api_engine"
require "standard_id/config/schema"
require "standard_id/errors"
require "standard_id/events"
require "standard_id/events/subscribers/base"
require "standard_id/events/subscribers/logging_subscriber"
require "standard_id/events/subscribers/audit_log_subscriber"
require "standard_id/http_client"
require "standard_id/jwt_service"
require "standard_id/web/session_manager"
require "standard_id/web/token_manager"
require "standard_id/web/authentication_guard"
require "standard_id/api/session_manager"
require "standard_id/api/token_manager"
require "standard_id/api/authentication_guard"
require "standard_id/oauth/base_request_flow"
require "standard_id/oauth/token_lifetime_resolver"
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
require "standard_id/passwordless/base_strategy"
require "standard_id/passwordless/email_strategy"
require "standard_id/passwordless/sms_strategy"
require "standard_id/utils/callable_parameter_filter"
require "standard_id/social_providers/google"
require "standard_id/social_providers/apple"

module StandardId
  class << self
    def configure(&block)
      StandardConfig.configure(&block)
    end

    def register(scope_name, resolver_proc)
      StandardConfig.config.register(scope_name, resolver_proc)
    end

    def config
      StandardConfig.config
    end

    def cache_store
      @cache_store ||= config.cache_store || Rails.cache
    end

    def logger
      @logger ||= config.logger || Rails.logger
    end

    def account_class
      config.account_class_name.constantize
    end
  end
end
