require "concurrent/map"

module StandardId
  class ProviderRegistry
    class ProviderNotFoundError < StandardError; end
    class InvalidProviderError < StandardError; end

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
        provider_class.setup if provider_class.respond_to?(:setup)
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
      # `validate_provider!` and the provider's `setup` — deliberately stays in
      # `after_initialize`, where the host's configuration is complete and
      # `setup` can rely on it.
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
          StandardId::ConfigSchema.add_field(scope: :social, name: field_name, **options)
        end
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
