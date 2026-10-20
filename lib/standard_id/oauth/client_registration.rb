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
    # one-time plaintext secret (confidential clients only) and, once migration
    # 20261020120000 has run, the one-time RFC 7592 registration access token;
    # on a metadata or redirect-uri problem it raises the matching RFC 7591
    # §3.2.2 error (InvalidRedirectUriError / InvalidClientMetadataError), which
    # the controller renders as HTTP 400. A nil owner resolver while the
    # feature is enabled raises ConfigurationError (a host-app bug, not client
    # input).
    #
    # `config.oauth.dynamic_registration_attributes` pins what the client may
    # not choose (scopes, metadata, lifetimes, consent); `.update` applies an
    # RFC 7592 §2.2 document to an existing client under the same rules, and
    # `.deregister` is RFC 7592 §2.3.
    class ClientRegistration
      # RFC 7591 grant_types we support. M2M (client_credentials) is deliberately
      # excluded from DCR — self-registered clients are public/interactive.
      ALLOWED_GRANT_TYPES = %w[authorization_code refresh_token].freeze
      # Only the authorization-code response type is supported.
      ALLOWED_RESPONSE_TYPES = %w[code].freeze
      # token_endpoint_auth_method -> client_type mapping.
      PUBLIC_AUTH_METHOD = "none".freeze
      CONFIDENTIAL_AUTH_METHODS = %w[client_secret_basic client_secret_post].freeze
      SUPPORTED_AUTH_METHODS = (CONFIDENTIAL_AUTH_METHODS + [PUBLIC_AUTH_METHOD]).freeze
      DEFAULT_SCOPE = "openid profile email".freeze
      # Keys `config.oauth.dynamic_registration_attributes` may pin.
      PINNABLE_ATTRIBUTES = %w[scopes metadata access_token_lifetime authorization_code_lifetime require_consent description].freeze
      REGISTRATION_ACCESS_TOKEN_BYTES = 32

      # Minimal result object mirroring the gem's `result.success?` /
      # `result.value` convention. `client_secret` is the one-time plaintext for
      # confidential clients (nil for public clients);
      # `registration_access_token` the one-time RFC 7592 credential (nil until
      # migration 20261020120000 has run, and on update).
      Result = Struct.new(:client, :client_secret, :token_endpoint_auth_method, :registration_access_token, keyword_init: true) do
        def success? = true
        def value = client
      end

      # @param metadata [Hash] RFC 7591 client metadata (symbolized or stringified keys)
      # @param request [ActionDispatch::Request, nil] handed to the owner and
      #   attributes callables
      # Accepts the document positionally or as keywords (`call(redirect_uris:
      # [...])`), since a bare Hash literal binds to keywords in Ruby 3.
      def initialize(metadata = nil, request: nil, **document)
        @metadata = (metadata || {}).to_h.merge(document).symbolize_keys
        @request = request
      end

      def self.call(metadata = nil, request: nil, **document)
        new(metadata, request: request, **document).call
      end

      # RFC 7592 §2.2: apply `metadata` to an already-registered `client`.
      # Only the client-shaped members change (client_name, redirect_uris,
      # grant_types, response_types, and scope unless pinned); the pinned
      # attributes, client_type, PKCE and the registration access token do not.
      # A `client_id` in the document must match; a `token_endpoint_auth_method`
      # must match the client's type (there is no secret rotation here).
      def self.update(client, metadata = nil, request: nil, **document)
        new(metadata, request: request, **document).update(client)
      end

      # RFC 7592 §2.3: the client stops being usable. Deactivated rather than
      # deleted so the refresh_token grant and introspection can say "gone"
      # (0.48.0 liveness); its live refresh tokens are revoked and its unused
      # authorization codes removed. The purge job deletes the row later.
      def self.deregister(client)
        now = Time.current
        StandardId::ClientApplication.transaction do
          client.deactivate!
          client.authorization_codes.where(consumed_at: nil).delete_all
          if StandardId::RefreshToken.client_binding_column?
            client.refresh_tokens.where(revoked_at: nil).update_all(revoked_at: now)
          end
        end
        client
      end

      def call
        attrs = mapped_attributes
        registration_access_token = nil
        if StandardId::ClientApplication.registration_management_column?
          registration_access_token = SecureRandom.urlsafe_base64(REGISTRATION_ACCESS_TOKEN_BYTES)
          attrs[:registration_access_token_digest] =
            StandardId::ClientApplication.digest_registration_access_token(registration_access_token)
        end
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

        Result.new(client: client, client_secret: secret_plaintext, token_endpoint_auth_method: auth_method,
          registration_access_token: registration_access_token)
      rescue ActiveRecord::RecordInvalid => e
        raise_for(e.record)
      end

      def update(client)
        if metadata[:client_id].present? && metadata[:client_id].to_s != client.client_id
          raise StandardId::InvalidClientMetadataError, "client_id does not match the client being updated"
        end

        requested_method = metadata[:token_endpoint_auth_method].to_s.strip
        if requested_method.present? && (requested_method == PUBLIC_AUTH_METHOD) != client.public?
          raise StandardId::InvalidClientMetadataError,
            "token_endpoint_auth_method cannot change a client between public and confidential"
        end

        attrs = {
          name: client_name,
          redirect_uris: redirect_uris,
          grant_types: grant_types,
          response_types: response_types
        }
        attrs[:scopes] = scope unless pinned.key?("scopes") || metadata[:scope].blank?

        client.update!(attrs)
        Result.new(client: client, token_endpoint_auth_method: client.token_endpoint_auth_method)
      rescue ActiveRecord::RecordInvalid => e
        raise_for(e.record)
      end

      private

      attr_reader :metadata, :request

      def mapped_attributes
        attrs = {
          owner: resolve_owner!,
          name: client_name,
          redirect_uris: redirect_uris,
          grant_types: grant_types,
          response_types: response_types,
          scopes: scope,
          client_type: client_type,
          require_pkce: require_pkce?,
          code_challenge_methods: code_challenge_methods,
          require_consent: pinned.fetch("require_consent", true)
        }
        attrs[:metadata] = pinned["metadata"].to_h.stringify_keys if pinned["metadata"].present?
        %w[access_token_lifetime authorization_code_lifetime description].each do |key|
          attrs[key.to_sym] = pinned[key] if pinned.key?(key)
        end
        attrs
      end

      # `config.oauth.dynamic_registration_attributes`, resolved for this
      # registration, keys stringified. An unknown key is a host bug.
      def pinned
        return @pinned if defined?(@pinned)

        configured = StandardId.config.oauth.dynamic_registration_attributes
        if configured.respond_to?(:call)
          args = StandardId::Utils::CallableParameterFilter.filter(configured, { metadata: metadata, request: request })
          configured = configured.call(**args)
        end
        resolved = (configured || {}).to_h.transform_keys(&:to_s)

        unknown = resolved.keys - PINNABLE_ATTRIBUTES
        if unknown.any?
          raise StandardId::ConfigurationError,
            "oauth.dynamic_registration_attributes has unknown key(s) #{unknown.inspect}; " \
            "allowed: #{PINNABLE_ATTRIBUTES.join(', ')}"
        end

        @pinned = resolved
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

      # Pinned scopes win over whatever was requested; a pinned audience with
      # a scope vocabulary is the next best server-side answer; only then the
      # requested scope.
      def scope
        if pinned.key?("scopes")
          return Array(pinned["scopes"]).flat_map { |v| v.to_s.split }.reject(&:blank?).uniq.join(" ")
        end

        audience = pinned.dig("metadata", "audience") || pinned.dig("metadata", :audience)
        if audience.present?
          vocabulary = StandardId::Oauth::AudienceScopeResolver.scopes_for(audience: audience.to_s)
          return vocabulary.join(" ") if vocabulary.any?
        end

        requested = metadata[:scope].to_s.strip
        requested.presence || DEFAULT_SCOPE
      end

      def auth_method
        method = metadata[:token_endpoint_auth_method].to_s.strip
        method.presence || default_auth_method
      end

      # Fallback token_endpoint_auth_method when the registration request omits
      # one. Reads the first-class config value (default "none"). A misconfigured
      # value is a host-app bug, so it raises ConfigurationError loudly rather
      # than silently registering a malformed client.
      def default_auth_method
        configured = StandardId.config.oauth.dynamic_registration_default_auth_method.to_s
        unless SUPPORTED_AUTH_METHODS.include?(configured)
          raise StandardId::ConfigurationError,
            "oauth.dynamic_registration_default_auth_method must be one of " \
            "#{SUPPORTED_AUTH_METHODS.join(', ')} (got #{configured.inspect})"
        end

        configured
      end

      def client_type
        method = auth_method
        allowed = allowed_auth_methods
        unless allowed.include?(method)
          raise StandardId::InvalidClientMetadataError,
            "Unsupported token_endpoint_auth_method: #{method.inspect}. " \
            "Allowed: #{allowed.join(', ')}"
        end

        method == PUBLIC_AUTH_METHOD ? "public" : "confidential"
      end

      # `config.oauth.dynamic_registration_auth_methods` ∩ what the gem supports.
      def allowed_auth_methods
        configured = Array(StandardId.config.oauth.dynamic_registration_auth_methods).map(&:to_s)
        allowed = configured & SUPPORTED_AUTH_METHODS
        return allowed if allowed.any?

        raise StandardId::ConfigurationError,
          "oauth.dynamic_registration_auth_methods must include at least one of #{SUPPORTED_AUTH_METHODS.join(', ')}"
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

        args = StandardId::Utils::CallableParameterFilter.filter(resolver, { metadata: metadata, request: request })
        owner = resolver.call(**args)
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
