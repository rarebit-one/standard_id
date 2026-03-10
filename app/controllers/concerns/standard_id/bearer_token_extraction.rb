# frozen_string_literal: true

module StandardId
  # Standalone concern for extracting Bearer tokens from the Authorization header.
  #
  # This is useful for controllers that need to extract a Bearer token but don't
  # use the full StandardId::ApiAuthentication flow (e.g., MCP endpoints,
  # provisioning APIs with custom token validation).
  #
  # Controllers that include StandardId::ApiAuthentication do NOT need this —
  # token extraction is handled internally by the TokenManager.
  #
  # @example
  #   class McpController < ActionController::API
  #     include StandardId::BearerTokenExtraction
  #
  #     def authenticate!
  #       token = extract_bearer_token
  #       # validate token...
  #     end
  #   end
  module BearerTokenExtraction
    extend ActiveSupport::Concern

    private

    # Extracts the token from an "Authorization: Bearer <token>" header.
    #
    # @return [String, nil] the bearer token, or nil if not present
    def extract_bearer_token
      request.headers["Authorization"]&.match(/\ABearer (.+)\z/)&.captures&.first
    end
  end
end
