require "concurrent/map"

module StandardId
  class ProviderRegistry
    class ProviderNotFoundError < StandardError; end
    class InvalidProviderError < StandardError; end

    # Keys a provider's `config_schema` entry may carry that belong to
    # StandardId (see Providers::Base) rather than to ConfigSchema.
    PROVIDER_FIELD_OPTIONS = %i[env required].freeze

    @providers = Concurrent::Map.new

    class << self
      def providers
        @providers
      end

      # Register a provider
      # @param name [Symbol, String] Provider identifier
      # @param provider_class [Class] Provider implementation class
      def register(name, provider_class)
        validate_provider!(provider_class)
        providers[name.to_s] = provider_class
        declare_config_schema(provider_class)
        provider_class
      end

      # Declare the `social` config fields of every provider class that has been
      # LOADED, whether or not it has been `register`ed yet.
      #
      # Called by a core Engine initializer that runs `before:
      # :load_config_initializers` — see StandardId::Engine. It exists because
      # provider plugins register themselves from their Railtie's
      # `config.after_initialize`, which runs long AFTER the host's
      # `config/initializers/standard_id.rb`. A host initializer writing
      # `c.social.google_client_id` therefore hit `Scope#[]=` → `validate!`
      # before the field existed and raised StandardId::ConfigurationError, with
      # nothing in the message to suggest the cause was ordering. Every consuming
      # app that used a provider plugin independently discovered the same
      # `Rails.application.config.after_initialize { ... }` wrapper to work
      # around it.
      #
      # This is safe to do early because provider classes are required at
      # gem-require time (`require "standard_id/google/providers/google"` in the
      # plugin's entry file), so `Providers::Base.subclasses` is already
      # populated before any initializer runs.
      #
      # Only FIELD DECLARATION moves earlier. Full `register` — which also runs
      # `validate_provider!` — deliberately stays in `after_initialize`, where
      # the host's configuration is complete.
      #
      # Idempotent: `ConfigSchema#add_field` uses `compute_if_absent`, so a field
      # already declared here is untouched when the plugin later calls `register`.
      #
      # @return [Array<Class>] the provider classes whose fields were declared
      def declare_config_schemas!
        provider_classes.each { |provider_class| declare_config_schema(provider_class) }
      end

      # Provider classes known to the process: every loaded subclass of
      # Providers::Base, plus anything already registered (a registered class
      # need not be a direct subclass).
      #
      # @return [Array<Class>]
      def provider_classes
        (StandardId::Providers::Base.subclasses + providers.values).uniq
      end

      # Declare one provider's config fields against the `social` scope.
      #
      # Thread-safe and idempotent — adding the same field twice is a no-op.
      #
      # `add_field` is retroactive: `ConfigSchema::Scope#validate!` and `#[]`
      # both consult the schema live (the latter falling back to
      # `field_for(...).default_value` for an unwritten key), so declaring a
      # field after `StandardId.config` has been built works exactly as if it
      # had been declared before. That is what makes the existing host-side
      # `after_initialize` wrappers keep working untouched.
      #
      # @param provider_class [Class] Provider implementation class
      def declare_config_schema(provider_class)
        return unless provider_class.respond_to?(:config_schema)

        schema = provider_class.config_schema
        return if schema.nil? || schema.empty?

        schema.each do |field_name, options|
          field_options = options.except(*PROVIDER_FIELD_OPTIONS)
          env_name = env_var_for(field_name, options)
          field_options[:default] = env_default(env_name, options[:default]) if env_name

          StandardId::ConfigSchema.add_field(scope: :social, name: field_name, **field_options)
        end
      end

      # The ENV variable a provider config field falls back to, or nil.
      #
      # Canonical scheme: the upper-cased field name (`apple_private_key` →
      # `APPLE_PRIVATE_KEY`). A provider overrides it per field with
      # `env: "OTHER_NAME"`, or opts out with `env: false`.
      #
      # @param field_name [Symbol, String]
      # @param options [Hash] the field's config_schema entry
      # @return [String, nil]
      def env_var_for(field_name, options = {})
        env = options.fetch(:env, true)
        return nil if env == false || env.nil?

        env == true ? field_name.to_s.upcase : env.to_s
      end

      # Registered providers the host app has switched on (see
      # Providers::Base.enabled?).
      #
      # @return [Hash{String => Class}] Provider name => class
      def enabled
        all.select { |_name, provider_class| provider_class.enabled? }
      end

      # Configuration problems across every registered provider.
      #
      # @return [Hash{String => Array<String>}] Provider name => errors, only
      #   for providers that have any
      def configuration_errors
        all.each_with_object({}) do |(name, provider_class), errors|
          provider_errors = provider_class.configuration_errors
          errors[name] = provider_errors if provider_errors.any?
        end
      end

      # Boot-time check that every enabled provider is fully configured.
      #
      # Run by StandardId::Engine once every plugin has registered. A provider
      # whose client ID is set but whose other required fields are not starts
      # its sign-in flow fine and only fails at the callback — after the user
      # has already authenticated with the provider — so this surfaces it at
      # boot instead.
      #
      # Behaviour follows `c.social.provider_misconfiguration`:
      # - `:warn` (default) — log a warning in every environment.
      # - `:raise` — raise StandardId::ConfigurationError in production; log a
      #   warning in every other environment, so a developer without production
      #   credentials can still boot the app.
      #
      # @param mode [Symbol] Override the configured mode
      # @param logger [Logger, nil]
      # @return [Hash{String => Array<String>}] the errors found
      # @raise [StandardId::ConfigurationError]
      def validate_configuration!(mode: StandardId.config.social.provider_misconfiguration, logger: StandardId.logger)
        errors = configuration_errors
        return errors if errors.empty?

        message = "StandardId social provider configuration is incomplete: " +
                  errors.map { |name, provider_errors| "#{name} (#{provider_errors.join('; ')})" }.join(", ")

        raise StandardId::ConfigurationError, message if mode.to_s == "raise" && production?

        logger&.warn("[StandardId] #{message}")
        errors
      end

      # Get provider by name
      # @param name [Symbol, String] Provider identifier
      # @return [Class] Provider class
      # @raise [ProviderNotFoundError] if provider not found
      def get(name)
        providers[name.to_s] || raise(
          ProviderNotFoundError,
          "Unknown provider: #{name}. Available providers: #{providers.keys.join(', ')}"
        )
      end

      # Get all registered providers
      # @return [Hash] Provider name => class mapping
      def all
        providers.each_pair.to_h
      end

      # Check if provider is registered
      # @param name [Symbol, String] Provider identifier
      # @return [Boolean]
      def registered?(name)
        providers.key?(name.to_s)
      end

      private

      # A default that prefers a non-blank ENV value, then the field's own
      # default. Evaluated lazily (ConfigSchema calls it when the config is
      # built, or on first read of a field declared afterwards), and only when
      # the host never assigned the field — an explicit assignment, even of
      # nil, always wins.
      def env_default(env_name, fallback)
        lambda do
          value = ENV[env_name]
          next value if value.present?

          fallback.respond_to?(:call) ? fallback.call : fallback
        end
      end

      def production?
        defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
      end

      def validate_provider!(provider_class)
        unless provider_class.is_a?(Class)
          raise InvalidProviderError,
                "Provider must be a class, got #{provider_class.class.name}"
        end

        unless provider_class < StandardId::Providers::Base
          raise InvalidProviderError,
                "Provider #{provider_class.name} must inherit from StandardId::Providers::Base"
        end
      end
    end
  end
end
