# frozen_string_literal: true

module StandardId
  # Bearer token extraction utility.
  #
  # Provides both a class-level method for use in lib/ code (TokenManager)
  # and a controller concern for use in app/ code.
  #
  # Controllers that include StandardId::ApiAuthentication do NOT need this —
  # token extraction is handled internally by the TokenManager.
  #
  # @example As a controller concern
  #   class McpController < ActionController::API
  #     include StandardId::BearerTokenExtraction
  #
  #     def authenticate!
  #       token = extract_bearer_token
  #       # validate token...
  #     end
  #   end
  #
  # @example Direct class method (used by TokenManager)
  #   StandardId::BearerTokenExtraction.extract(auth_header)
  module BearerTokenExtraction
    # Extracts the Bearer token from a raw Authorization header value.
    #
    # Note: prior to this extraction, TokenManager#bearer_token returned ""
    # for a bare "Bearer " header. This now returns nil via .presence, which
    # is the correct behavior — downstream JWT parsing receives nil instead
    # of attempting to decode an empty string.
    #
    # @param auth_header [String, nil] the raw Authorization header value
    # @return [String, nil] the bearer token, or nil if not present/empty
    def self.extract(auth_header)
      return unless auth_header&.start_with?("Bearer ")

      auth_header.split(" ", 2).last.presence
    end

    private

    # Extracts the token from an "Authorization: Bearer <token>" header.
    # Result is memoized for the lifetime of the controller instance.
    #
    # @return [String, nil] the bearer token, or nil if not present
    def extract_bearer_token
      return @_bearer_token if defined?(@_bearer_token)

      @_bearer_token = StandardId::BearerTokenExtraction.extract(request.headers["Authorization"])
    end
  end
end
