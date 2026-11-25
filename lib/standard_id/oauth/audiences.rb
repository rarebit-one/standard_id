module StandardId
  module Oauth
    # The two audience lists an app works with, resolved from config:
    #
    #   * mintable — audiences this app may issue tokens for (every
    #     TokenGrantFlow, so /oauth/token for each grant including the
    #     authorization-code exchange and client_credentials, plus
    #     TokenMinter / DirectMintFlow and the API step-up re-mint).
    #   * accepted — audiences the API token manager accepts on a bearer at
    #     decode time.
    #
    # Each is `oauth.mintable_audiences` / `oauth.accepted_audiences` when the
    # host set it (nil means unset), else `oauth.allowed_audiences`, so a host
    # that sets neither sees one list doing both jobs, as it always did. An
    # identity provider that mints tokens for other services (aud=harness,
    # aud=inference) lists them in mintable_audiences and keeps
    # accepted_audiences to its own API's audiences, so those service tokens
    # are not also accepted on it.
    #
    # An empty effective list means no restriction on that side, as an empty
    # allowed_audiences always has.
    #
    # On top of the accepted list, `oauth.endpoint_audiences` narrows what each
    # of the gem's own bearer endpoints accepts (see .endpoint).
    module Audiences
      # The gem's bearer endpoints that return or change the account's data,
      # by their `oauth.endpoint_audiences` key.
      ENDPOINTS = %i[userinfo sessions step_up].freeze

      module_function

      # @return [Array<String>]
      def mintable
        resolve(StandardId.config.oauth.mintable_audiences)
      end

      # @return [Array<String>]
      def accepted
        resolve(StandardId.config.oauth.accepted_audiences)
      end

      # The audiences `oauth.endpoint_audiences` lets +endpoint+ accept. Empty
      # when the host set none, which means any accepted audience.
      #
      # @param endpoint [Symbol] one of ENDPOINTS
      # @return [Array<String>]
      def endpoint(endpoint)
        map = StandardId.config.oauth.endpoint_audiences || {}
        list = map.key?(endpoint.to_sym) ? map[endpoint.to_sym] : map[endpoint.to_s]
        Array(list).map(&:to_s).reject(&:blank?)
      end

      # ENDPOINTS that `oauth.endpoint_audiences` leaves open.
      #
      # @return [Array<Symbol>]
      def unrestricted_endpoints
        ENDPOINTS.select { |name| endpoint(name).empty? }
      end

      # A mistyped key would leave its endpoint open without a word, so refuse
      # it at boot.
      #
      # @raise [StandardId::ConfigurationError]
      def validate_endpoint_audiences!
        map = StandardId.config.oauth.endpoint_audiences || {}
        unknown = map.keys.map(&:to_s) - ENDPOINTS.map(&:to_s)
        return if unknown.empty?

        raise StandardId::ConfigurationError,
          "config.oauth.endpoint_audiences has unknown endpoint(s) #{unknown.join(', ')}; " \
          "expected any of #{ENDPOINTS.join(', ')}"
      end

      def resolve(override)
        list = override.nil? ? StandardId.config.oauth.allowed_audiences : override
        Array(list).map(&:to_s)
      end
      private_class_method :resolve
    end
  end
end
