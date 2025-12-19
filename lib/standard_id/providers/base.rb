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
        # Returns a hash of field definitions compatible with StandardConfig schema DSL.
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
      end
    end
  end
end
