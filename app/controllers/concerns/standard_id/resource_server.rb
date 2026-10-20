# frozen_string_literal: true

module StandardId
  # The bearer check a resource server (an MCP endpoint, a service API) needs,
  # in one line:
  #
  #   class Mcp::BaseController < ActionController::API
  #     include StandardId::ResourceServer
  #     protected_resource "mcp", scopes: %w[mcp]
  #   end
  #
  # It verifies the access token (ApiAuthentication), requires the token's
  # `aud` to carry the resource's audience (AudienceVerification, including the
  # audience → profile-type binding when configured), requires one of `scopes:`
  # when given, and answers every refusal the way RFC 6750 and the MCP
  # authorization spec expect:
  #
  #   * 401 `invalid_token` for a missing, expired, revoked or otherwise invalid
  #     token, and for a deactivated or locked account, with a
  #     `WWW-Authenticate` challenge that names the RFC 9728 metadata document
  #     for this resource (`resource_metadata=`) so a client can discover the
  #     authorization server and start the authorization-code + PKCE flow;
  #   * 403 `insufficient_scope` for a token minted for another audience, or
  #     without a required scope, with the same pointer and (for scope) the
  #     `scope` parameter listing what the resource needed.
  #
  # The audience must be configured in `config.oauth.protected_resources`
  # (see StandardId::Oauth::ProtectedResourceDocument) so the challenge can
  # name a document that exists. Anything else — rate limiting, resolving the
  # token's `gid` to a profile — stays the host's, as before.
  module ResourceServer
    extend ActiveSupport::Concern

    included do
      include StandardId::ApiAuthentication unless include?(StandardId::ApiAuthentication)

      # Order matters: AudienceVerification's verify_audience! returns early
      # unless current_session is set, so the token must be verified first.
      before_action :verify_access_token!

      include StandardId::AudienceVerification

      before_action :verify_protected_resource_scopes!

      class_attribute :_protected_resource_audience, instance_writer: false, default: nil
      class_attribute :_protected_resource_scopes, instance_writer: false, default: []

      rescue_from StandardId::NotAuthenticatedError,
        StandardId::InvalidSessionError,
        StandardId::InvalidTokenError,
        StandardId::AccountDeactivatedError,
        StandardId::AccountLockedError,
        with: :render_protected_resource_unauthorized

      # Registered after AudienceVerification's own handler so this one wins:
      # same 403 insufficient_scope, same generic description, plus the
      # resource_metadata pointer.
      rescue_from StandardId::InvalidAudienceError,
        StandardId::InvalidAudienceProfileError,
        with: :render_protected_resource_wrong_audience

      rescue_from StandardId::InvalidScopeError, with: :render_protected_resource_insufficient_scope
    end

    class_methods do
      # @param audience [String] the audience configured in
      #   `config.oauth.protected_resources` that tokens for this resource carry
      # @param scopes [Array<String>, String, nil] when given, the token must
      #   carry at least one of these
      def protected_resource(audience, scopes: nil)
        self._protected_resource_audience = audience.to_s
        self._protected_resource_scopes = Array(scopes).flat_map { |s| s.to_s.split }.reject(&:blank?).uniq
        verify_audience audience.to_s
      end
    end

    private

    def protected_resource_audience
      _protected_resource_audience.presence ||
        raise(StandardId::ConfigurationError, "#{self.class.name} includes StandardId::ResourceServer but never called protected_resource")
    end

    # Like verify_audience!: without a session there is nothing to check, and
    # either the auth layer is answering the 401 or the action skipped
    # verify_access_token! on purpose (a 405 responder, say).
    def verify_protected_resource_scopes!
      return if _protected_resource_scopes.empty?
      return unless current_session

      require_scopes!(*_protected_resource_scopes)
    end

    def protected_resource_metadata_url
      StandardId::Oauth::ProtectedResourceDocument.metadata_url(audience: protected_resource_audience, origin: request.base_url)
    end

    # The description never carries operator- or user-authored text: it goes
    # into a quoted header and to an unauthenticated caller.
    #
    # RFC 6750 §3.1: when the request carried no credential at all, the
    # challenge names the realm and the metadata document but no error code —
    # that is the form an MCP client sees first, before it has any token.
    def render_protected_resource_unauthorized(error = nil)
      if request.authorization.blank?
        set_protected_resource_challenge!(error: nil)
        render json: { error: "invalid_token", error_description: "An access token is required" }, status: :unauthorized
        return
      end

      description = case error
      when StandardId::AccountDeactivatedError then "The account is deactivated"
      when StandardId::AccountLockedError then "The account is locked"
      else "The access token is invalid or has expired"
      end
      set_protected_resource_challenge!(error: "invalid_token", error_description: description)
      render json: { error: "invalid_token", error_description: description }, status: :unauthorized
    end

    def render_protected_resource_wrong_audience(_error)
      description = StandardId::AudienceVerification::GENERIC_INSUFFICIENT_SCOPE_MESSAGE
      set_protected_resource_challenge!(error: "insufficient_scope", error_description: description)
      render json: { error: "insufficient_scope", error_description: description }, status: :forbidden
    end

    def render_protected_resource_insufficient_scope(error)
      description = error.message.presence || "The access token is missing a required scope"
      set_protected_resource_challenge!(error: "insufficient_scope", error_description: description, scope: _protected_resource_scopes)
      render json: { error: "insufficient_scope", error_description: description }, status: :forbidden
    end

    def set_protected_resource_challenge!(error:, error_description: nil, scope: nil)
      response.set_header(
        "WWW-Authenticate",
        StandardId::Oauth::ProtectedResourceDocument.challenge(
          audience: protected_resource_audience, origin: request.base_url,
          error: error, error_description: error_description, scope: scope
        )
      )
    end
  end
end
