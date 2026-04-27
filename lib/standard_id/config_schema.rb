require "active_support/ordered_options"
require "concurrent/map"

module StandardId
  # Lightweight configuration schema backed by ActiveSupport::OrderedOptions.
  # Replaces the vendored `StandardConfig` DSL/manager. Fields are declared
  # per scope; the resulting top-level config exposes each scope as a nested
  # OrderedOptions and routes any field whose name is unique across scopes
  # to the owning scope (so host apps can read base-scope fields like
  # `config.account_class_name` without the `base.` prefix).
  class ConfigSchema
    Field = Struct.new(:name, :type, :default) do
      def default_value
        return default.call if default.respond_to?(:call)
        return default.dup if default.is_a?(Array) || default.is_a?(Hash)
        default
      end
    end

    class << self
      def instance = (@instance ||= new)
      def define(&block) = instance.define(&block)
      def add_field(**kwargs) = instance.add_field(**kwargs)
      def build = instance.apply(Config.new)
    end

    def initialize = @scopes = Concurrent::Map.new
    def scopes = @scopes
    def scope?(name) = @scopes.key?(name.to_sym)
    def field?(scope_name, field_name) = !!@scopes[scope_name.to_sym]&.key?(field_name.to_sym)
    def field_for(scope_name, field_name) = @scopes[scope_name.to_sym]&.[](field_name.to_sym)

    def define(&block)
      DSL.new(self).instance_eval(&block) if block
      self
    end

    def add_field(scope:, name:, type: :string, default: nil)
      fields = ensure_scope(scope)
      fields.compute_if_absent(name.to_sym) { Field.new(name.to_sym, type, default) }
    end

    # Register a scope without adding a field. Allows `define { scope :foo }` so
    # provider gems can later `add_field(scope: :foo, ...)` against an existing scope.
    def ensure_scope(name)
      @scopes.compute_if_absent(name.to_sym) { Concurrent::Map.new }
    end

    # Scopes that declare a field with the given name (used for top-level routing).
    def scopes_with_field(field_name)
      sym = field_name.to_sym
      @scopes.each_pair.with_object([]) { |(s, fs), acc| acc << s if fs.key?(sym) }
    end

    # Populate the given Config with scope sub-options + defaults. Re-apply is safe;
    # values already set in a Scope are preserved (so provider gems can register
    # fields after host apps have set base values).
    def apply(config)
      config.__schema__ = self
      @scopes.each_pair do |scope_name, fields|
        opts = (config.key?(scope_name) && config[scope_name].is_a?(Scope)) ? config[scope_name] : Scope.new(self, scope_name)
        fields.each_value { |f| opts.write_default(f.name, f.default_value) }
        config.write_raw(scope_name, opts)
      end
      config
    end

    def cast(value, type)
      return value if value.nil?
      case type
      when :any     then value
      when :symbol  then value.is_a?(Symbol) ? value : value.to_sym
      when :string  then value.to_s
      when :integer then value.to_i
      when :float   then value.to_f
      when :array   then Array(value)
      when :hash    then value.is_a?(Hash) ? value : {}
      when :boolean
        case value
        when true, false then value
        when "true", "1", 1 then true
        when "false", "0", 0 then false
        else !!value
        end
      else value
      end
    end

    # DSL: `define { scope :base do field :foo, type: :string, default: "x" end }`.
    # Anonymous-class form keeps both levels in one place; #scope yields a sub-DSL
    # that closes over the parent schema + scope name.
    class DSL
      def initialize(schema, scope_name = nil)
        @schema = schema
        @scope_name = scope_name
      end

      def scope(name, &block)
        @schema.ensure_scope(name)
        DSL.new(@schema, name.to_sym).instance_eval(&block) if block
      end

      def field(name, type: :string, default: nil, **)
        @schema.add_field(scope: @scope_name, name: name, type: type, default: default)
      end
    end

    # Per-scope OrderedOptions. Validates writes, casts and dups Array/Hash values
    # on read. When `resolver` is set (via `Config#register`), reads delegate to
    # the resolver-returned hash for dynamic / multi-tenant configuration.
    class Scope < ActiveSupport::OrderedOptions
      RAW_SET = ActiveSupport::OrderedOptions.instance_method(:[]=)
      private_constant :RAW_SET

      attr_accessor :resolver

      def initialize(schema, scope_name)
        super()
        @schema = schema
        @scope_name = scope_name
      end

      def []=(key, value)
        validate!(key)
        super(key.to_sym, value)
      end

      def [](key)
        sym = key.to_sym
        validate!(sym) unless key?(sym) || resolver
        raw = if resolver
                hash = resolver.call || {}
                if hash.respond_to?(:key?) && hash.respond_to?(:[])
                  hash.key?(sym) ? hash[sym] : hash[sym.to_s]
                end
        elsif key?(sym)
                super(sym)
        else
                @schema.field_for(@scope_name, sym)&.default_value
        end
        cast_read(sym, raw)
      end

      def write_default(key, value)
        return if key?(key.to_sym)
        RAW_SET.bind_call(self, key.to_sym, value)
      end

      private

      def validate!(key)
        return if @schema.field?(@scope_name, key)
        raise StandardId::ConfigurationError,
          "Unknown field '#{key}' for scope '#{@scope_name}'. Valid fields: #{@schema.scopes[@scope_name]&.keys}"
      end

      def cast_read(key, value)
        field = @schema.field_for(@scope_name, key)
        return value unless field
        casted = @schema.cast(value, field.type)
        casted.is_a?(Array) || casted.is_a?(Hash) ? casted.dup : casted
      end
    end

    # Top-level config: routes unqualified field reads/writes to the owning scope
    # when the name is unique across scopes.
    class Config < ActiveSupport::OrderedOptions
      RAW_SET = ActiveSupport::OrderedOptions.instance_method(:[]=)
      private_constant :RAW_SET

      attr_accessor :__schema__

      def register(scope_name, resolver)
        sym = scope_name.to_sym
        unless __schema__&.scope?(sym)
          raise ArgumentError, "Unknown configuration scope: #{sym}. Valid scopes: #{__schema__&.scopes&.keys}"
        end
        self[sym].resolver = resolver
        self
      end

      def registered?(scope_name) = !!self[scope_name.to_sym]&.resolver

      def [](key)
        sym = key.to_sym
        return super if key?(sym) || __schema__.nil? || __schema__.scope?(sym)
        target = unique_scope_for(sym)
        target ? self[target][sym] : super
      end

      def []=(key, value)
        sym = key.to_sym
        if __schema__ && !__schema__.scope?(sym) && !key?(sym) && (target = unique_scope_for(sym))
          self[target][sym] = value
        else
          super(sym, value)
        end
      end

      # Bypass routing — used by the schema applier.
      def write_raw(key, value) = RAW_SET.bind_call(self, key.to_sym, value)

      private

      def unique_scope_for(name)
        matches = __schema__.scopes_with_field(name)
        matches.size == 1 ? matches.first : nil
      end
    end
  end
end
