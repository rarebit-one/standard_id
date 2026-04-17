# frozen_string_literal: true

module StandardId
  # Per-controller audience verification for API endpoints.
  #
  # While StandardId validates that the JWT `aud` claim is in the global
  # `allowed_audiences` list, this concern provides additional defense-in-depth
  # by restricting which audiences are accepted by each controller.
  #
  # In addition, when `StandardId.config.oauth.audience_profile_types` is set,
  # this concern enforces the audience → profile-type binding: after the
  # allowed-audience check, it resolves the current account's profile for the
  # matched audience and rejects requests whose profile type does not match.
  #
  # Requires StandardId::ApiAuthentication to be included before this concern
  # (provides `verify_access_token!` and `current_session`). An error is raised
  # at include time if ApiAuthentication is missing.
  #
  # The caller is responsible for registering `before_action :verify_access_token!`
  # (typically via ApiAuthentication or a base controller). This concern only adds
  # the `verify_audience!` callback, which must run after token verification so
  # that `current_session` is populated. This is consistent with how
  # `require_scopes!` works in ApiAuthentication.
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
      unless ancestors.include?(StandardId::ApiAuthentication)
        raise "#{name || 'Controller'} must include StandardId::ApiAuthentication before StandardId::AudienceVerification"
      end

      before_action :verify_audience!

      rescue_from StandardId::InvalidAudienceError, with: :handle_invalid_audience
      rescue_from StandardId::InvalidAudienceProfileError, with: :handle_invalid_audience

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

    # Verifies the token's `aud` claim contains at least one of the required audiences,
    # then enforces audience → profile-type binding when configured.
    # Supports both string and array `aud` claims.
    #
    # @raise [StandardId::InvalidAudienceError] when no audience matches
    # @raise [StandardId::InvalidAudienceProfileError] when the account's
    #   profile type does not match the configured binding for the matched audience
    def verify_audience!
      return if _required_audiences.empty?

      # If authentication hasn't run (or token is invalid), let the auth
      # layer handle 401 — don't mask it with a 403.
      return unless current_session

      token_audiences = Array(current_session.aud)
      matched = (token_audiences & _required_audiences).first

      if matched.nil?
        raise StandardId::InvalidAudienceError.new(
          required: _required_audiences,
          actual: token_audiences
        )
      end

      enforce_audience_profile_binding!(matched, token_audiences)
    end

    # Enforce `audience_profile_types[matched]` against the current account.
    # No-op when the audience has no binding configured (back-compat).
    def enforce_audience_profile_binding!(matched_audience, token_audiences)
      expected_types = StandardId::Oauth::AudienceProfileResolver.profile_types_for(matched_audience)
      return if expected_types.empty?

      profile = StandardId::Oauth::AudienceProfileResolver.call(
        account: current_account,
        audience: matched_audience
      )
      actual_type = profile_type_name(profile)

      return if actual_type && expected_types.include?(actual_type)

      # For audit purposes, when there is no matching profile, report the
      # first profile type the account actually has (if any) so operators can
      # see what the client was carrying instead.
      actual_type ||= fallback_actual_profile_type

      error = StandardId::InvalidAudienceProfileError.new(
        audience: matched_audience,
        expected_profile_types: expected_types,
        actual_profile_type: actual_type,
        required: _required_audiences,
        actual: token_audiences
      )
      emit_audience_mismatch(error)
      raise error
    end

    def profile_type_name(profile)
      return nil if profile.nil?
      return profile.profileable_type.to_s if profile.respond_to?(:profileable_type)
      return profile.type.to_s if profile.respond_to?(:type)

      profile.class.name.to_s
    end

    # When no matching profile exists for the audience, surface the first
    # profile type the account carries (if any) to aid debugging/audit. This
    # never changes the decision — the mismatch is already confirmed when
    # this is called — it only enriches the error/event payload.
    def fallback_actual_profile_type
      account = current_account
      return nil if account.nil? || !account.respond_to?(:profiles)

      candidates = account.profiles
      candidates = candidates.to_a unless candidates.is_a?(Array)
      first = candidates.first
      profile_type_name(first)
    end

    def emit_audience_mismatch(error)
      StandardId::Events.publish(
        StandardId::Events::OAUTH_AUDIENCE_MISMATCH,
        audience: error.audience,
        token_audiences: error.actual,
        required_audiences: error.required,
        expected_profile_types: error.expected_profile_types,
        actual_profile_type: error.actual_profile_type,
        account: (current_account if respond_to?(:current_account, true))
      )
    rescue StandardError => e
      StandardId.config.logger&.warn(
        "[StandardId] failed to emit oauth.audience.mismatch event: #{e.class}: #{e.message}"
      )
    end

    # Returns 403 Forbidden per RFC 6750 §3.1 (insufficient_scope).
    # Includes WWW-Authenticate header per spec, consistent with the gem's
    # 401 handling in Api::BaseController#render_bearer_unauthorized!.
    #
    # The header uses a static description rather than interpolating
    # error.message (which contains raw aud values from the JWT) to
    # avoid header injection via crafted audience strings.
    #
    # Override in your controller for custom error formatting.
    def handle_invalid_audience(error)
      response.set_header(
        "WWW-Authenticate",
        'Bearer error="insufficient_scope", error_description="The access token audience is not permitted for this resource"'
      )
      render json: { error: "insufficient_scope", error_description: error.message }, status: :forbidden
    end
  end
end
