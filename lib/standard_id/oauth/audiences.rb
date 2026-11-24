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
    module Audiences
      module_function

      # @return [Array<String>]
      def mintable
        resolve(StandardId.config.oauth.mintable_audiences)
      end

      # @return [Array<String>]
      def accepted
        resolve(StandardId.config.oauth.accepted_audiences)
      end

      def resolve(override)
        list = override.nil? ? StandardId.config.oauth.allowed_audiences : override
        Array(list).map(&:to_s)
      end
      private_class_method :resolve
    end
  end
end
