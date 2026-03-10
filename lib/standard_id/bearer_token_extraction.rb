# frozen_string_literal: true

module StandardId
  # Bearer token extraction utility.
  #
  # This module serves two roles:
  #
  # 1. **Class method** (`BearerTokenExtraction.extract`) — pure extraction
  #    logic used by TokenManager in lib/. Lives in lib/ so there is no
  #    cross-layer dependency on app/ autoloading.
  #
  # 2. **Controller mixin** (`include StandardId::BearerTokenExtraction`) —
  #    provides `extract_bearer_token` as a private instance method.
  #    Conventionally, controller concerns live under app/controllers/concerns/,
  #    but this module is co-located with the utility to keep the extraction
  #    logic in a single file and avoid the same-constant-name conflict
  #    between lib/ and app/ autoloading.
  #
  # Does not use ActiveSupport::Concern because it has no `included` or
  # `class_methods` blocks — it is a plain Ruby module.
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
    # Note: prior to the introduction of this module, TokenManager#bearer_token
    # returned "" for a bare "Bearer " header. This now returns nil via .presence,
    # which is the correct behavior — downstream JWT parsing receives nil instead
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
