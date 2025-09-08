require "ostruct"

module StandardConfig
  class ConfigProvider
    def initialize(scope_name, resolver_proc, schema = nil)
      @scope_name = scope_name
      @resolver_proc = resolver_proc
      @schema = schema
    end

    def method_missing(method_name, *args)
      if method_name.to_s.end_with?('=')
        # Setter - only works for static configs (OpenStruct objects)
        field_name = method_name.to_s.chomp('=').to_sym
        validate_field!(field_name)

        config_object = @resolver_proc.call
        if config_object.respond_to?(method_name)
          config_object.send(method_name, args.first)
        elsif config_object.respond_to?(:[]=)
          # Support hash-like providers
          value = args.first
          config_object[field_name] = value
          # Also set string key for convenience if symbol not used by provider
          begin
            config_object[field_name.to_s] = value
          rescue StandardError
            # ignore if provider doesn't accept string keys
          end
        else
          raise NoMethodError, "Configuration object doesn't support setting #{field_name}"
        end
      else
        # Getter
        get_field(method_name)
      end
    end

    def get_field(field_name)
      validate_field!(field_name)

      config_object = @resolver_proc.call
      raw_value = if config_object.respond_to?(field_name)
                    config_object.send(field_name)
                  elsif config_object.respond_to?(:[])
                    config_object[field_name] || config_object[field_name.to_s]
                  else
                    nil
                  end

      # Cast the value according to schema
      field_def = @schema&.field_definition(@scope_name, field_name)
      return raw_value unless field_def

      casted = @schema&.cast_value(raw_value, field_def.type) || raw_value
      # Return dup for mutable structures to prevent accidental mutation of shared defaults
      if casted.is_a?(Array)
        casted.dup
      elsif casted.is_a?(Hash)
        casted.dup
      else
        casted
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      field_name = method_name.to_s.end_with?('=') ? method_name.to_s.chomp('=').to_sym : method_name.to_sym
      @schema&.valid_field?(@scope_name, field_name) || super
    end

    private

    def validate_field!(field_name)
      return unless @schema # Skip validation if no schema provided

      unless @schema.valid_field?(@scope_name, field_name)
        valid_fields = @schema.scopes[@scope_name]&.fields&.keys || []
        raise ArgumentError, "Unknown field '#{field_name}' for scope '#{@scope_name}'. Valid fields: #{valid_fields}"
      end
    end
  end
end
