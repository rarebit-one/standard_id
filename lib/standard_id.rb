require "standard_id/version"
require "standard_id/engine"
require "standard_id/web_engine"
require "standard_id/api_engine"
require "standard_id/config"
require "standard_id/errors"
require "standard_id/web/session_manager"
require "standard_id/web/token_manager"
require "standard_id/web/authentication_guard"
require "standard_id/api/session_manager"
require "standard_id/api/token_manager"
require "standard_id/api/authentication_guard"

module StandardId
  class << self
    def configure
      yield config
    end

    def config
      @config ||= StandardId::Config.new
    end

    def cache_store
      @cache_store ||= config.cache_store || Rails.cache
    end

    def logger
      @logger ||= config.logger || Rails.logger
    end
  end
end
