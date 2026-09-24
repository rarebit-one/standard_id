require "uri"
require "active_support/security_utils"

module StandardId
  module Providers
    # Base class for social login providers.
    #
    # All provider implementations (Google, Apple, GitHub, etc.) must inherit from this class
    # and implement the required interface methods. This enables a plugin architecture where
    # provider gems can be developed independently and registered with StandardId.
    #
    # @example Creating a custom provider
    #   module StandardId
    #     module Providers
    #       class GitHub < Base
    #         def self.provider_name
    #           "github"
    #         end
    #
    #         def self.authorization_url(state:, redirect_uri:, **options)
    #           # Build and return GitHub OAuth authorization URL
    #         end
    #
    #         def self.get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, **options)
    #           # Exchange credentials for user info and return standardized response
    #         end
    #
    #         def self.config_schema
    #           {
    #             github_client_id: { type: :string, default: nil },
    #             github_client_secret: { type: :string, default: nil }
    #           }
    #         end
    #       end
    #     end
    #   end
    #
    #   # Register the provider
    #   StandardId::ProviderRegistry.register(:github, StandardId::Providers::GitHub)
    #
    class Base
      class << self
        # Provider identifier used for routing and configuration.
        #
        # @return [String] Unique provider name (e.g., "google", "apple", "github")
        # @raise [NotImplementedError] if not overridden by subclass
        #
        # @example
        #   StandardId::Providers::Google.provider_name #=> "google"
        #
        def provider_name
          raise NotImplementedError, "#{name} must implement .provider_name"
        end

        # Generate OAuth authorization URL for redirecting users to the provider.
        #
        # @param state [String] OAuth state parameter (typically encoded with redirect + session info)
        # @param redirect_uri [String] Callback URL where provider will redirect after authentication
        # @param options [Hash] Provider-specific options (scope, prompt, response_mode, etc.)
        # @return [String] Full authorization URL to redirect user to
        # @raise [NotImplementedError] if not overridden by subclass
        #
        # @example
        #   url = StandardId::Providers::Google.authorization_url(
        #     state: "encoded_state_data",
        #     redirect_uri: "https://app.example.com/auth/callback/google",
        #     scope: "openid email profile"
        #   )
        #
        def authorization_url(state:, redirect_uri:, **options)
          raise NotImplementedError, "#{name} must implement .authorization_url"
        end

        # Exchange OAuth credentials for user information.
        #
        # Providers must support at least one of: authorization code, ID token, or access token.
        # The method should validate the credentials with the provider and return standardized
        # user information.
        #
        # @param code [String, nil] OAuth authorization code (web flow)
        # @param id_token [String, nil] JWT ID token (mobile/implicit flow)
        # @param access_token [String, nil] Access token (implicit flow)
        # @param redirect_uri [String, nil] Original redirect_uri for code exchange validation
        # @param options [Hash] Provider-specific options (client_id for Apple mobile, etc.)
        # @return [HashWithIndifferentAccess] Standardized response with user_info and tokens
        # @raise [NotImplementedError] if not overridden by subclass
        # @raise [StandardId::InvalidRequestError] if credentials are missing or invalid
        # @raise [StandardId::OAuthError] if provider returns an error
        #
        # @example Response format
        #   {
        #     user_info: {
        #       "sub" => "unique_provider_user_id",
        #       "email" => "user@example.com",
        #       "email_verified" => true,
        #       "name" => "Full Name",
        #       # ... other provider-specific fields
        #     },
        #     tokens: {
        #       id_token: "...",
        #       access_token: "...",
        #       refresh_token: "..."
        #     }
        #   }
        #
        def get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, **options)
          raise NotImplementedError, "#{name} must implement .get_user_info"
        end

        # Define configuration schema fields for this provider.
        #
        # Returns a hash of field definitions compatible with the StandardId::ConfigSchema DSL.
        # These fields will be registered under the :social configuration scope.
        #
        # @return [Hash] Field definitions with types and defaults
        #
        # @example
        #   def self.config_schema
        #     {
        #       github_client_id: { type: :string, default: nil },
        #       github_client_secret: { type: :string, default: nil }
        #     }
        #   end
        #
        def config_schema
          {}
        end

        # Resolve provider-specific parameters based on context.
        #
        # Override this method to customize parameters based on flow type,
        # platform, or other contextual information. This allows providers
        # to handle platform-specific requirements (e.g., Apple's different
        # client IDs for web vs mobile).
        #
        # @param params [Hash] Base parameters from the controller
        # @param context [Hash] Contextual information
        # @option context [Symbol] :flow The authentication flow (:web or :mobile)
        # @return [Hash] Modified parameters with provider-specific adjustments
        #
        # @example Apple provider overriding for mobile flow
        #   def self.resolve_params(params, context: {})
        #     if context[:flow] == :mobile
        #       params.merge(client_id: StandardId.config.apple_mobile_client_id)
        #     else
        #       params
        #     end
        #   end
        #
        def resolve_params(params, context: {})
          params
        end

        # Returns the callback path for this provider.
        #
        # Used to build the OAuth redirect URI. Uses the engine's route helpers
        # to respect the mount path.
        #
        # @return [String] The callback path (respects engine mount path)
        #
        # @example Engine mounted at "/"
        #   StandardId::Providers::Google.callback_path #=> "/auth/callback/google"
        #
        # @example Engine mounted at "/identity"
        #   StandardId::Providers::Google.callback_path #=> "/identity/auth/callback/google"
        #
        def callback_path
          StandardId::WebEngine.routes.url_helpers.auth_callback_provider_path(provider: provider_name)
        end

        # Returns the default OAuth scope for this provider.
        #
        # Can be overridden by passing :scope in authorization_url options.
        # Returns nil by default, letting the provider use its own default.
        #
        # @return [String, nil] Default scope string
        #
        # @example
        #   StandardId::Providers::Google.default_scope #=> "openid email profile"
        #
        def default_scope
          nil
        end

        # Whether to skip CSRF verification for web callbacks.
        #
        # Some providers (like Apple) use POST callbacks which require
        # CSRF verification to be skipped. Override this method to return
        # true if your provider uses POST callbacks.
        #
        # @return [Boolean] true to skip CSRF verification
        #
        # @example Apple provider (POST callback)
        #   def self.skip_csrf?
        #     true
        #   end
        #
        def skip_csrf?
          false
        end

        # Whether this provider supports mobile callback flow.
        #
        # Mobile callbacks are used when native apps (especially Android)
        # need a server-side redirect back to the app after OAuth.
        # For example, Apple Sign In on Android uses a web-based flow
        # that requires the server to redirect back to the app.
        #
        # @return [Boolean] true if provider supports mobile callback
        #
        def supports_mobile_callback?
          false
        end

        # Returns list of supported authorization parameters for this provider.
        #
        # Include :nonce in this list for OIDC providers to enable nonce validation.
        # Nonce provides replay attack protection for ID tokens.
        #
        # @return [Array<Symbol>] List of supported parameters
        #
        # @example
        #   def supported_authorization_params
        #     [:scope, :prompt, :nonce]
        #   end
        #
        def supported_authorization_params
          []
        end

        # --------------------------------------------------------------------
        # Configuration & enablement
        # --------------------------------------------------------------------
        #
        # Each entry returned by {config_schema} may carry two provider-level
        # options in addition to the ConfigSchema ones (`type:`, `default:`).
        # They are consumed by StandardId and never reach ConfigSchema:
        #
        # - `env:` — the ENV variable the field falls back to when the host app
        #   never assigns it. Defaults to the upper-cased field name
        #   (`google_client_id` → `GOOGLE_CLIENT_ID`), which is the canonical
        #   naming scheme. Pass a String to use another variable, or `false` to
        #   disable the ENV fallback for that field. Explicit configuration
        #   (`c.social.google_client_id = ...`, including an explicit `nil`)
        #   always wins over the ENV fallback.
        # - `required: true` — the field must be present whenever the provider
        #   is {enabled?}. Missing required fields are reported by
        #   {configuration_errors} and by the boot-time check (see
        #   `c.social.provider_misconfiguration`).
        #
        # Both options require standard_id >= 0.42. A plugin that declares them
        # should depend on `standard_id >= 0.42` — older versions pass the
        # options through to ConfigSchema and raise ArgumentError.
        #
        # @example
        #   def self.config_schema
        #     {
        #       github_client_id: { type: :string, default: nil },
        #       github_client_secret: { type: :string, default: nil, required: true },
        #       github_enterprise_host: { type: :string, default: nil, env: false }
        #     }
        #   end

        # Config field whose presence switches this provider on.
        #
        # Defaults to `:"<provider_name>_client_id"` when that field is part of
        # {config_schema}, otherwise nil (a provider with no enabling field is
        # always enabled once registered). Override when the provider keys off a
        # different field.
        #
        # @return [Symbol, nil]
        def enabling_config_field
          field = :"#{provider_name}_client_id"
          config_schema.key?(field) ? field : nil
        end

        # Config fields that must be present whenever the provider is enabled.
        #
        # Defaults to the {config_schema} fields declared with `required: true`.
        #
        # @return [Array<Symbol>]
        def required_config_fields
          config_schema.select { |_name, options| options.is_a?(Hash) && options[:required] }.keys.map(&:to_sym)
        end

        # Whether the host app has switched this provider on.
        #
        # True when {enabling_config_field} is present in the configuration (or
        # when the provider has no enabling field). Says nothing about whether
        # the rest of the configuration is complete — see {configuration_errors}
        # and {configured?}.
        #
        # @return [Boolean]
        def enabled?
          field = enabling_config_field
          return true if field.nil?

          config_value(field).present?
        end

        # Human-readable problems with this provider's configuration.
        #
        # Empty when the provider is disabled: a provider nobody switched on
        # cannot be misconfigured. Messages name fields, never their values.
        #
        # @return [Array<String>]
        def configuration_errors
          return [] unless enabled?

          missing = required_config_fields.select { |field| config_value(field).blank? }
          return [] if missing.empty?

          trigger = enabling_config_field ? " when #{enabling_config_field} is set" : ""
          missing.map { |field| "#{field} is required#{trigger}" }
        end

        # Enabled and free of {configuration_errors}.
        #
        # @return [Boolean]
        def configured?
          enabled? && configuration_errors.empty?
        end

        # The flow a native/API callback is running, used as `context[:flow]`
        # for {resolve_params}.
        #
        # Called by the API callback endpoint (`/api/oauth/callback/:provider`).
        # The default honours an explicit `flow=web` param only for providers
        # that {supports_mobile_callback?} — those are the providers whose web
        # and native flows differ (e.g. Apple's distinct Services ID vs bundle
        # ID audiences). Everything else is treated as `:mobile`, which is what
        # the API endpoint served before this hook existed. Override to
        # recognise other flows.
        #
        # @param params [#[]] Request params
        # @return [Symbol] `:web` or `:mobile`
        def flow_for(params)
          return :mobile unless supports_mobile_callback?

          params[:flow].to_s.downcase == "web" ? :web : :mobile
        end

        # Optional setup hook called when provider is registered.
        #
        # Override this method to perform initialization tasks like:
        # - Registering additional routes
        # - Adding custom validations
        # - Setting up caching for JWKS
        #
        # @return [void]
        #
        def setup
          # Override in subclasses if needed
        end

        protected

        # Helper to build standardized response format.
        #
        # @param user_info [Hash] User information from provider
        # @param tokens [Hash] OAuth tokens (id_token, access_token, refresh_token)
        # @return [HashWithIndifferentAccess] Standardized response
        #
        def build_response(user_info, tokens: {})
          {
            user_info: user_info,
            tokens: tokens.compact
          }.with_indifferent_access
        end

        # Read one of this provider's config fields.
        #
        # Goes through the top-level `StandardId.config` accessor — the same
        # way the provider plugins read their own credentials — so the value
        # seen here always matches the one the provider will use.
        #
        # @param field [Symbol, String]
        # @return [Object, nil]
        def config_value(field)
          StandardId.config.public_send(field)
        end

        # Run the block, re-raising any non-OAuth error as StandardId::OAuthError.
        #
        # StandardId::OAuthError (and subclasses such as InvalidRequestError)
        # propagate unchanged. Anything else — network, JSON, OpenSSL, JWT
        # errors — is wrapped so callers only ever handle OAuthError, with the
        # original exception kept as `cause`.
        #
        # @param message_prefix [String, nil] Prepended to the wrapped error's
        #   message, e.g. "Failed to fetch JWK" → "Failed to fetch JWK: <msg>"
        # @return [Object] the block's return value
        # @raise [StandardId::OAuthError]
        #
        # @example
        #   def fetch_user_info(access_token:)
        #     rescue_to_oauth_error do
        #       response = HttpClient.get_with_bearer(USERINFO_ENDPOINT, access_token)
        #       JSON.parse(response.body)
        #     end
        #   end
        #
        def rescue_to_oauth_error(message_prefix = nil)
          yield
        rescue StandardId::OAuthError
          raise
        rescue StandardError => e
          message = message_prefix ? "#{message_prefix}: #{e.message}" : e.message
          raise StandardId::OAuthError, message, cause: e
        end

        # Verify an ID token's `nonce` claim against the one the server issued.
        #
        # No-op when `expected` is blank (flows without a server-generated
        # nonce). Comparison is constant-time. The error message deliberately
        # does not include either nonce: the expected value is a server-side
        # secret for the duration of the flow, and error messages end up in
        # redirects, logs and error trackers.
        #
        # @param expected [String, nil] Nonce stored when the flow started
        # @param actual [String, nil] `nonce` claim from the verified ID token
        # @return [void]
        # @raise [StandardId::InvalidRequestError] on mismatch
        def verify_nonce!(expected:, actual:)
          return if expected.blank?
          return if actual.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(actual, expected.to_s)

          raise StandardId::InvalidRequestError, "ID token nonce mismatch"
        end

        # Build an OAuth 2.0 authorization-code URL.
        #
        # Emits `client_id`, `redirect_uri`, `response_type`, `state`, then one
        # entry per {supported_authorization_params}, taking the caller's value
        # from `options` or falling back to `defaults`. Nil values are dropped.
        #
        # @param endpoint [String] Provider authorization endpoint
        # @param client_id [String]
        # @param redirect_uri [String]
        # @param state [String]
        # @param options [Hash] Caller-supplied authorization params
        # @param defaults [Hash] Per-param fallbacks (e.g. `{ scope: "openid email" }`)
        # @param response_type [String]
        # @return [String]
        #
        # @example
        #   def self.authorization_url(state:, redirect_uri:, **options)
        #     build_authorization_url(
        #       endpoint: AUTH_ENDPOINT,
        #       client_id: StandardId.config.github_client_id,
        #       redirect_uri:, state:, options:,
        #       defaults: { scope: DEFAULT_SCOPE }
        #     )
        #   end
        #
        def build_authorization_url(endpoint:, client_id:, redirect_uri:, state:, options: {}, defaults: {}, response_type: "code")
          query = {
            client_id: client_id,
            redirect_uri: redirect_uri,
            response_type: response_type,
            state: state
          }

          supported_authorization_params.each do |param|
            query[param] = options[param] || defaults[param]
          end

          "#{endpoint}?#{URI.encode_www_form(query.compact)}"
        end

        # Pick the standard tokens out of a token-endpoint response.
        #
        # @param parsed_token [Hash] Parsed token response (String or Symbol keys)
        # @return [Hash{Symbol => String}] `access_token`, `refresh_token` and
        #   `id_token`, nil entries removed
        def extract_tokens(parsed_token)
          %i[access_token refresh_token id_token].each_with_object({}) do |key, tokens|
            value = parsed_token[key.to_s] || parsed_token[key]
            tokens[key] = value unless value.nil?
          end
        end
      end
    end
  end
end
