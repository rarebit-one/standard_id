require "securerandom"

module StandardId
  module Oauth
    # RFC 7591 Dynamic Client Registration.
    #
    # Maps a client metadata document (the JSON body of POST /oauth/register)
    # onto a StandardId::ClientApplication, applying the engine's security
    # defaults (PKCE-forced public clients, S256, consent-by-default) and a
    # conservative whitelist of grant/response types. Keeps the controller thin
    # in the same flow-object style as the other lib/standard_id/oauth/ objects.
    #
    # On success #call returns a Result carrying the persisted client plus the
    # one-time plaintext secret (confidential clients only); on a metadata or
    # redirect-uri problem it raises the matching RFC 7591 §3.2.2 error
    # (InvalidRedirectUriError / InvalidClientMetadataError), which the
    # controller renders as HTTP 400. A nil owner resolver while the feature is
    # enabled raises ConfigurationError (a host-app bug, not client input).
    class ClientRegistration
      # RFC 7591 grant_types we support. M2M (client_credentials) is deliberately
      # excluded from DCR — self-registered clients are public/interactive.
      ALLOWED_GRANT_TYPES = %w[authorization_code refresh_token].freeze
      # Only the authorization-code response type is supported.
      ALLOWED_RESPONSE_TYPES = %w[code].freeze
      # token_endpoint_auth_method -> client_type mapping.
      PUBLIC_AUTH_METHOD = "none".freeze
      CONFIDENTIAL_AUTH_METHODS = %w[client_secret_basic client_secret_post].freeze
      DEFAULT_AUTH_METHOD = PUBLIC_AUTH_METHOD
      DEFAULT_SCOPE = "openid profile email".freeze

      # Minimal result object mirroring the gem's `result.success?` /
      # `result.value` convention. `client_secret` is the one-time plaintext for
      # confidential clients (nil for public clients).
      Result = Struct.new(:client, :client_secret, keyword_init: true) do
        def success? = true
        def value = client
      end

      # @param metadata [Hash] RFC 7591 client metadata (symbolized or stringified keys)
      def initialize(metadata)
        @metadata = (metadata || {}).to_h.symbolize_keys
      end

      def self.call(metadata)
        new(metadata).call
      end

      def call
        attrs = mapped_attributes
        client = StandardId::ClientApplication.new(attrs)

        secret_plaintext = nil
        StandardId::ClientApplication.transaction do
          client.save!
          if client.confidential?
            secret_plaintext = SecureRandom.hex(32)
            client.create_client_secret!(
              name: "Dynamic Registration Secret",
              client_secret: secret_plaintext
            )
          end
        end

        Result.new(client: client, client_secret: secret_plaintext)
      rescue ActiveRecord::RecordInvalid => e
        raise_for(e.record)
      end

      private

      attr_reader :metadata

      def mapped_attributes
        {
          owner: resolve_owner!,
          name: client_name,
          redirect_uris: redirect_uris,
          grant_types: grant_types,
          response_types: response_types,
          scopes: scope,
          client_type: client_type,
          require_pkce: require_pkce?,
          code_challenge_methods: code_challenge_methods,
          require_consent: true
        }
      end

      # redirect_uris is REQUIRED (RFC 7591 §2). We pass the raw value through to
      # the model and let its redirect-uri validation surface an invalid_redirect_uri
      # error — keeping a single source of truth for URI rules.
      def redirect_uris
        Array(metadata[:redirect_uris]).map { |u| u.to_s.strip }.reject(&:blank?).join(" ")
      end

      def client_name
        name = metadata[:client_name].to_s.strip
        name.presence || "Dynamically Registered Client #{SecureRandom.hex(4)}"
      end

      # Whitelist grant_types. Any value outside ALLOWED_GRANT_TYPES is rejected
      # as invalid_client_metadata (RFC 7591 §3.2.2). Absent -> authorization_code.
      def grant_types
        requested = list_param(:grant_types)
        return "authorization_code" if requested.empty?

        disallowed = requested - ALLOWED_GRANT_TYPES
        if disallowed.any?
          raise StandardId::InvalidClientMetadataError,
            "Unsupported grant_types: #{disallowed.join(', ')}. Allowed: #{ALLOWED_GRANT_TYPES.join(', ')}"
        end

        requested.join(" ")
      end

      def response_types
        requested = list_param(:response_types)
        return "code" if requested.empty?

        disallowed = requested - ALLOWED_RESPONSE_TYPES
        if disallowed.any?
          raise StandardId::InvalidClientMetadataError,
            "Unsupported response_types: #{disallowed.join(', ')}. Allowed: #{ALLOWED_RESPONSE_TYPES.join(', ')}"
        end

        requested.join(" ")
      end

      def scope
        scope = metadata[:scope].to_s.strip
        scope.presence || DEFAULT_SCOPE
      end

      def auth_method
        method = metadata[:token_endpoint_auth_method].to_s.strip
        method.presence || DEFAULT_AUTH_METHOD
      end

      def client_type
        method = auth_method
        return "public" if method == PUBLIC_AUTH_METHOD
        return "confidential" if CONFIDENTIAL_AUTH_METHODS.include?(method)

        raise StandardId::InvalidClientMetadataError,
          "Unsupported token_endpoint_auth_method: #{method.inspect}. " \
          "Allowed: #{(CONFIDENTIAL_AUTH_METHODS + [PUBLIC_AUTH_METHOD]).join(', ')}"
      end

      # Public clients are always forced onto PKCE/S256 (the model also validates
      # this). Confidential clients also default to PKCE here for defense in depth.
      def require_pkce?
        true
      end

      def code_challenge_methods
        "S256"
      end

      def resolve_owner!
        resolver = StandardId.config.oauth.dynamic_registration_owner
        unless resolver.respond_to?(:call)
          raise StandardId::ConfigurationError,
            "oauth.dynamic_registration_owner must be set to a callable resolving the " \
            "client owner when oauth.dynamic_registration_enabled is true " \
            "(e.g. -> { Organization.default })"
        end

        owner = resolver.call
        if owner.nil?
          raise StandardId::ConfigurationError,
            "oauth.dynamic_registration_owner resolved to nil; it must return the " \
            "polymorphic owner record for dynamically registered clients"
        end

        owner
      end

      # Accept either an Array or a space-delimited String for list-shaped
      # metadata fields (RFC 7591 uses JSON arrays; be lenient with strings too).
      def list_param(key)
        value = metadata[key]
        case value
        when Array
          value.map { |v| v.to_s.strip }.reject(&:blank?)
        else
          value.to_s.split(/\s+/).map(&:strip).reject(&:blank?)
        end
      end

      # Translate an ActiveRecord validation failure into the matching RFC 7591
      # error. A redirect_uris failure is invalid_redirect_uri; everything else
      # (including a blank redirect_uris which the model reports as a presence
      # error) maps to invalid_client_metadata.
      def raise_for(record)
        errors = record.errors
        message = errors.full_messages.join("; ")

        if errors.key?(:redirect_uris)
          raise StandardId::InvalidRedirectUriError, message.presence || "Invalid redirect_uris"
        end

        raise StandardId::InvalidClientMetadataError, message.presence || "Invalid client metadata"
      end
    end
  end
end
