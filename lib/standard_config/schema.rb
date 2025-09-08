module StandardConfig
  class Schema
    def initialize
      @scopes = {}
    end

    # DSL entry
    def draw(&block)
      Drawer.new(self).instance_eval(&block) if block_given?
      self
    end

    def scopes
      @scopes
    end

    def scope(name, &block)
      name_sym = name.to_sym
      builder = scopes[name_sym] ||= ScopeBuilder.new(name_sym)
      builder.instance_eval(&block) if block_given?
      builder
    end

    def valid_scope?(name)
      scopes.key?(name.to_sym)
    end

    def valid_field?(scope_name, field_name)
      return false unless valid_scope?(scope_name)
      scopes[scope_name.to_sym].fields.key?(field_name.to_sym)
    end

    def field_definition(scope_name, field_name)
      return nil unless valid_scope?(scope_name)
      scopes[scope_name.to_sym].fields[field_name.to_sym]
    end

    # Return an array of scope names that define the given field
    def scopes_with_field(field_name)
      scopes.keys.select { |s| scopes[s].fields.key?(field_name.to_sym) }
    end

    def cast_value(value, type)
      return value if value.nil?

      case type
      when :any
        value
      when :string
        value.to_s
      when :integer
        value.to_i
      when :float
        value.to_f
      when :boolean
        case value
        when true, false then value
        when 'true', '1', 1 then true
        when 'false', '0', 0 then false
        else !!value
        end
      when :array
        Array(value)
      when :hash
        value.is_a?(Hash) ? value : {}
      else
        value
      end
    end

    class ScopeBuilder
      attr_reader :name, :fields

      def initialize(name)
        @name = name.to_sym
        @fields = {}
      end

      def field(name, type: :string, default: nil, readonly: false)
        key = name.to_sym
        if @fields.key?(key)
          Kernel.warn("[StandardId::Configuration] Redefining field '#{key}' in scope '#{@name}'. Last definition wins.")
        end
        @fields[key] = FieldDefinition.new(name, type: type, default: default, readonly: readonly)
      end
    end

    class FieldDefinition
      attr_reader :name, :type, :default, :readonly

      def initialize(name, type: :string, default: nil, readonly: false)
        @name = name.to_sym
        @type = type
        @default = default
        @readonly = readonly
      end

      def default_value
        if @default.respond_to?(:call)
          @default.call
        elsif @default.is_a?(Array)
          @default.dup
        else
          @default
        end
      end
    end

    # Internal DSL driver
    class Drawer
      def initialize(schema)
        @schema = schema
      end

      # scope :base do ... end OR scope :passwordless do ... end
      def scope(name, &block)
        name_sym = name.to_sym
        # Ensure scope exists, then evaluate the block in a scoped context
        @schema.scope(name_sym)
        ScopedScope.new(@schema, name_sym).instance_eval(&block) if block_given?
      end
    end

    class ScopedScope
      def initialize(schema, scope_name)
        @schema = schema
        @scope_name = scope_name
      end

      def field(name, type: :string, default: nil, readonly: false)
        # Add field to the last declared scope by using ScopeBuilder within @schema.scope
        # This method will be called inside Schema.scope block via Drawer
        @schema.scopes[@scope_name].field(name, type: type, default: default, readonly: readonly)
      end
    end
  end
end
