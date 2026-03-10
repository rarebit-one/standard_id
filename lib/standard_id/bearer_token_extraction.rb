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
    extend ActiveSupport::Concern

    # Extracts the Bearer token from a raw Authorization header value.
    #
    # @param auth_header [String, nil] the raw Authorization header value
    # @return [String, nil] the bearer token, or nil if not present/empty
    def self.extract(auth_header)
      return unless auth_header&.start_with?("Bearer ")

      auth_header.split(" ", 2).last.presence
    end

    private

    # Extracts the token from an "Authorization: Bearer <token>" header.
    #
    # @return [String, nil] the bearer token, or nil if not present
    def extract_bearer_token
      StandardId::BearerTokenExtraction.extract(request.headers["Authorization"])
    end
  end
end
