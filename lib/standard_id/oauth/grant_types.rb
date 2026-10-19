module StandardId
  module Oauth
    # The one reader for `config.oauth.disabled_grant_types`, so the token
    # endpoint (which refuses a disabled grant) and the discovery documents
    # (which stop advertising it) can never normalise the list differently.
    module GrantTypes
      # @return [Array<String>] grant_type strings the host has turned off
      def self.disabled
        Array(StandardId.config.oauth.disabled_grant_types).map(&:to_s)
      end

      # @param name [String, Symbol, nil] a `grant_type` value
      def self.disabled?(name)
        disabled.include?(name.to_s)
      end
    end
  end
end
