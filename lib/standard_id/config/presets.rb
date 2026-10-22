module StandardId
  module Config
    # Named bundles of settings, applied with `c.preset :name`.
    #
    # The public defaults suit a classic server-rendered app with password
    # sign-up. Apps built the other way round (Inertia pages, passwordless or
    # social sign-in, ApiEngine under a path prefix) flip the same handful of
    # settings, so a preset names that bundle instead of changing the defaults
    # for everyone else.
    #
    # A preset fills only settings the host has not assigned, so an explicit
    # `c.web.signup = true` wins whether it comes before or after the preset.
    module Presets
      PRESETS = {
        # Inertia-rendered web surface with no password sign-up, login or
        # reset (sign-in is passwordless or social; which of those is on stays
        # the host's call), and discovery endpoints built from the request so
        # an ApiEngine mounted under a prefix advertises the right URLs.
        inertia_web: {
          base: { use_inertia: true, alias_current_user: true },
          web: { signup: false, password_login: false, password_reset: false },
          oauth: { discovery_endpoint_base: :request }
        }
      }.freeze

      module_function

      # @param config [StandardId::ConfigSchema::Config]
      # @param name [Symbol, String]
      # @raise [ArgumentError] for an unknown preset name
      # @return [config]
      def apply(config, name)
        settings = PRESETS.fetch(name.to_sym) do
          raise ArgumentError, "Unknown StandardId config preset: #{name.inspect}. Valid presets: #{PRESETS.keys.map(&:inspect).join(", ")}"
        end

        settings.each do |scope_name, values|
          scope = config[scope_name]
          values.each { |key, value| scope[key] = value unless scope.assigned?(key) }
        end
        config
      end
    end
  end
end
