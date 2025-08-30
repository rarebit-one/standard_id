require "standard_id/version"
require "standard_id/engine"
require "standard_id/config"

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
