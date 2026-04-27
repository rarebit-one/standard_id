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
        register_config_schema(provider_class)
        provider_class.setup if provider_class.respond_to?(:setup)
        provider_class
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

      # Register provider's config schema fields with the StandardId schema.
      # Thread-safe and idempotent — adding the same field twice is a no-op.
      # @param provider_class [Class] Provider implementation class
      def register_config_schema(provider_class)
        schema = provider_class.config_schema
        return if schema.nil? || schema.empty?

        schema.each do |field_name, options|
          StandardId::ConfigSchema.add_field(scope: :social, name: field_name, **options)
        end
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
