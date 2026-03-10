# frozen_string_literal: true

module StandardId
  # Per-controller audience verification for API endpoints.
  #
  # While StandardId validates that the JWT `aud` claim is in the global
  # `allowed_audiences` list, this concern provides additional defense-in-depth
  # by restricting which audiences are accepted by each controller.
  #
  # Requires StandardId::ApiAuthentication to be included (provides
  # `verify_access_token!` and `current_session`).
  #
  # The caller is responsible for registering `before_action :verify_access_token!`
  # (typically via ApiAuthentication or a base controller). This concern only adds
  # the `verify_audience!` callback, consistent with how `require_scopes!` works.
  #
  # @example Single audience
  #   class AdminController < Api::BaseController
  #     include StandardId::AudienceVerification
  #     verify_audience "admin"
  #   end
  #
  # @example Multiple audiences
  #   class SharedController < Api::BaseController
  #     include StandardId::AudienceVerification
  #     verify_audience "admin", "mobile"
  #   end
  module AudienceVerification
    extend ActiveSupport::Concern

    included do
      before_action :verify_audience!

      rescue_from StandardId::InvalidAudienceError, with: :handle_invalid_audience

      # Underscore prefix follows Rails class_attribute convention to avoid
      # collisions with application method names.
      class_attribute :_required_audiences, instance_writer: false, default: []
    end

    class_methods do
      # Declare the allowed audiences for this controller.
      # The token's `aud` claim must include at least one of these values.
      #
      # @param audiences [Array<String>] allowed JWT `aud` claim values
      def verify_audience(*audiences)
        self._required_audiences = audiences.flatten.map(&:to_s)
      end
    end

    private

    # Verifies the token's `aud` claim contains at least one of the required audiences.
    # Supports both string and array `aud` claims.
    #
    # @raise [StandardId::InvalidAudienceError] when no audience matches
    def verify_audience!
      return if _required_audiences.empty?

      token_audiences = Array(current_session&.aud)
      return if (token_audiences & _required_audiences).any?

      raise StandardId::InvalidAudienceError.new(
        required: _required_audiences,
        actual: token_audiences
      )
    end

    # Returns 403 Forbidden per RFC 6750 §3.1 (insufficient_scope).
    # Includes WWW-Authenticate header per spec, consistent with the gem's
    # 401 handling in Api::BaseController#render_bearer_unauthorized!.
    # Override in your controller for custom error formatting.
    def handle_invalid_audience(error)
      response.set_header(
        "WWW-Authenticate",
        %Q(Bearer error="insufficient_scope", error_description="#{error.message}")
      )
      render json: { error: "insufficient_scope", error_description: error.message }, status: :forbidden
    end
  end
end
