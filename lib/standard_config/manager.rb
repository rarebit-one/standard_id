require "ostruct"
require "standard_config/config_provider"

module StandardConfig
  class Manager
    def initialize(schema)
      @schema = schema
      @providers = {}
    end

    # Register a configuration provider for a scope
    def register(scope_name, resolver_proc)
      scope_name = scope_name.to_sym

      # Validate scope exists in schema
      unless @schema.valid_scope?(scope_name)
        raise ArgumentError, "Unknown configuration scope: #{scope_name}. Valid scopes: #{@schema.scopes.keys}"
      end

      @providers[scope_name] = ConfigProvider.new(scope_name, resolver_proc, @schema)
      self
    end

    def registered?(scope_name)
      @providers.key?(scope_name.to_sym)
    end

    # Access configuration scopes via method calls
    def method_missing(method_name, *args)
      method_str = method_name.to_s
      scope_name = method_str.end_with?("=") ? method_str.chomp("=").to_sym : method_name.to_sym

      # Handle field setter via unique scope resolution
      if method_str.end_with?("=")
        field = scope_name
        scopes = @schema.scopes_with_field(field)
        if scopes.size == 1
          s = scopes.first
          register(s, -> { create_static_config_for_scope(s) }) unless @providers.key?(s)
          @providers[s].public_send(method_name, *args)
          return args.first
        end
      end

      # Handle field getter via unique scope resolution
      scopes = @schema.scopes_with_field(scope_name)
      if scopes.size == 1
        s = scopes.first
        register(s, -> { create_static_config_for_scope(s) }) unless @providers.key?(s)
        return @providers[s].get_field(scope_name)
      end

      # Handle scope access
      if @providers.key?(scope_name)
        return @providers[scope_name]
      end

      # Create static provider for valid scopes on first access
      if @schema.valid_scope?(scope_name)
        register(scope_name, -> { create_static_config_for_scope(scope_name) })
        return @providers[scope_name]
      end

      super
    end

    def respond_to_missing?(method_name, include_private = false)
      method_str = method_name.to_s
      scope_name = method_str.end_with?("=") ? method_str.chomp("=").to_sym : method_name.to_sym
      @schema.valid_scope?(scope_name) ||
        @schema.scopes_with_field(scope_name).any? ||
        super
    end

    private

    def create_static_config_for_scope(scope_name)
      @static_configs ||= {}
      @static_configs[scope_name] ||= OpenStruct.new.tap do |config|
        @schema.scopes[scope_name].fields.each do |field_name, field_def|
          config.send("#{field_name}=", field_def.default_value)
        end
      end
    end
  end
end
