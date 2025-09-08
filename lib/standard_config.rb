require "standard_config/config"
require "standard_config/config_provider"
require "standard_config/manager"
require "standard_config/schema"

module StandardConfig
  class << self
    def schema
      @schema ||= Schema.new
    end

    def configure(&block)
      config.register(:base, block) unless config.registered?(:base) if block_given? && block.arity == 0

      yield config if block_given?

      config
    end

    def config
      @manager ||= Manager.new(schema)
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
