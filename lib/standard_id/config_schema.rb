require "active_support/ordered_options"
require "concurrent/map"
require "standard_id/deprecator"

module StandardId
  # Lightweight configuration schema backed by ActiveSupport::OrderedOptions.
  # Replaces the vendored `StandardConfig` DSL/manager. Fields are declared
  # per scope; the resulting top-level config exposes each scope as a nested
  # OrderedOptions and routes any field whose name is unique across scopes
  # to the owning scope (so host apps can read base-scope fields like
  # `config.account_class_name` without the `base.` prefix).
  class ConfigSchema
    # +deprecation+ is a message (String) for a field kept only so existing
    # host initializers still boot. Assigning a non-nil value warns through
    # StandardId.deprecator; reads and schema defaults never warn.
    Field = Struct.new(:name, :type, :default, :deprecation) do
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

    def initialize
      @scopes = Concurrent::Map.new
      @removed = Concurrent::Map.new
    end

    def scopes = @scopes
    def scope?(name) = @scopes.key?(name.to_sym)
    def field?(scope_name, field_name) = !!@scopes[scope_name.to_sym]&.key?(field_name.to_sym)
    def field_for(scope_name, field_name) = @scopes[scope_name.to_sym]&.[](field_name.to_sym)

    def define(&block)
      DSL.new(self).instance_eval(&block) if block
      self
    end

    def add_field(scope:, name:, type: :string, default: nil, deprecated: nil)
      fields = ensure_scope(scope)
      fields.compute_if_absent(name.to_sym) { Field.new(name.to_sym, type, default, deprecated) }
    end

    # Record a field that has been REMOVED from the schema. Assigning it raises
    # StandardId::ConfigurationError carrying +message+ (what to do instead),
    # rather than the generic "Unknown field" — or, for a base-scope field
    # assigned through the top-level config, rather than being silently
    # stored on the top-level OrderedOptions and ignored.
    def add_removed_field(scope:, name:, message:)
      @removed[[scope.to_sym, name.to_sym]] = message
    end

    # @return [String, nil] the removal hint for a removed field, else nil
    def removed_field_message(scope_name, field_name) = @removed[[scope_name.to_sym, field_name.to_sym]]

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

      def field(name, type: :string, default: nil, deprecated: nil, **)
        @schema.add_field(scope: @scope_name, name: name, type: type, default: default, deprecated: deprecated)
      end

      def removed(name, message)
        @schema.add_removed_field(scope: @scope_name, name: name, message: message)
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
        warn_if_deprecated(key, value)
        assigned_keys << key.to_sym
        super(key.to_sym, value)
      end

      # Whether the host explicitly assigned +key+ (even to nil).
      #
      # Unlike #key?, which is also true for every field whose schema default
      # was written when the config was built (so it is true for a provider
      # field the host never touched), this is only true after an assignment.
      #
      # @param key [Symbol, String]
      # @return [Boolean]
      def assigned?(key) = assigned_keys.include?(key.to_sym)

      # Deleting a key also forgets that it was assigned, so reads fall back
      # to the (live) schema default again.
      def delete(key)
        assigned_keys.delete(key.to_sym)
        super(key.to_sym)
      end

      # Re-evaluate the schema default of every field the host never assigned.
      #
      # Defaults are resolved once, when the config is built — including the
      # ENV fallback of provider fields (`GOOGLE_CLIENT_ID` etc.). Call this
      # after changing ENV to make unassigned fields pick the new value up;
      # explicitly assigned fields are left alone. Meant for tests — see
      # StandardId::Testing.with_provider_env.
      #
      # @return [self]
      def refresh_defaults!
        @schema.scopes[@scope_name]&.each_value do |field|
          next if assigned?(field.name)

          RAW_SET.bind_call(self, field.name, field.default_value)
        end
        self
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

      def assigned_keys = (@assigned_keys ||= Set.new)

      def validate!(key)
        return if @schema.field?(@scope_name, key)
        if (message = @schema.removed_field_message(@scope_name, key))
          raise StandardId::ConfigurationError,
            "StandardId.config.#{config_path(key)} was removed in StandardId 0.43: #{message}"
        end
        raise StandardId::ConfigurationError,
          "Unknown field '#{key}' for scope '#{@scope_name}'. Valid fields: #{@schema.scopes[@scope_name]&.keys}"
      end

      def warn_if_deprecated(key, value)
        return if value.nil?

        message = @schema.field_for(@scope_name, key)&.deprecation
        return if message.nil?

        # Point the warning at the host's assignment, not at this file.
        # (OrderedOptions' method_missing forwards `c.foo = x` to #[]=.)
        callstack = caller_locations(1).reject do |location|
          location.path == __FILE__ || location.path.end_with?("active_support/ordered_options.rb")
        end
        StandardId.deprecator.warn("StandardId.config.#{config_path(key)} is deprecated: #{message}", callstack)
      end

      def config_path(key)
        @scope_name == :base ? key.to_s : "#{@scope_name}.#{key}"
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
        elsif __schema__ && (message = __schema__.removed_field_message(:base, sym))
          raise StandardId::ConfigurationError,
            "StandardId.config.#{sym} was removed in StandardId 0.43: #{message}"
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
