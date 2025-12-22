require "standard_config/config"
require "standard_config/config_provider"
require "standard_config/manager"
require "standard_config/schema"

require "concurrent/delay"

module StandardConfig
  SCHEMA = Concurrent::Delay.new { Schema.new }
  MANAGER = Concurrent::Delay.new { Manager.new(SCHEMA.value) }

  class << self
    def schema
      SCHEMA.value
    end

    def configure(&block)
      if block_given? && block.arity.zero? && !config.registered?(:base)
        config.register(:base, block)
      end

      yield config if block_given?

      config
    end

    def config
      MANAGER.value
    end

    private

    def create_default_config
      require "ostruct"
      static_config = OpenStruct.new
      base_scope = schema.scopes[:base]
      if base_scope
        base_scope.fields.each do |field_name, field_def|
          static_config.send("#{field_name}=", field_def.default_value)
        end
      end
      static_config
    end
  end
end
