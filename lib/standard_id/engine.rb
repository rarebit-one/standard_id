require "standard_id/config/callable_validator"
require "standard_id/config/scope_claims_validator"
# Ensure the StandardId error hierarchy is loaded at engine boot time so that
# host apps can reference constants like `StandardId::SocialLinkError` at
# class-body load time (e.g. `rescue_from StandardId::SocialLinkError`) without
# relying on Zeitwerk autoload ordering or falling back to string literals.
require "standard_id/errors"

module StandardId
  class Engine < ::Rails::Engine
    isolate_namespace StandardId

    initializer "standard_id.filter_parameters" do |app|
      app.config.filter_parameters += %i[
        code_verifier
        code_challenge
        client_secret
        id_token
        refresh_token
        access_token
        state
        nonce
        authorization_code
      ]
    end

    config.after_initialize do |app|
      if StandardId.config.events.enable_logging
        StandardId::Events::Subscribers::LoggingSubscriber.attach
      end

      StandardId::Events::Subscribers::AccountStatusSubscriber.attach
      StandardId::Events::Subscribers::AccountLockingSubscriber.attach
      StandardId::Events::Subscribers::PasswordlessDeliverySubscriber.attach
      StandardId::Events::Subscribers::PasswordResetDeliverySubscriber.attach

      if StandardId.config.issuer.blank?
        Rails.logger.warn("[StandardId] No issuer configured. JWT tokens will not include or verify the 'iss' claim. " \
                          "Set StandardId.config.issuer in your initializer for production use.")
      end

      # Validate configured callables have the right shape and that every
      # claim listed in scope_claims has a resolver registered. Raising here
      # surfaces typos at boot instead of at callback time in production.
      StandardId::Config::CallableValidator.validate!
      StandardId::Config::ScopeClaimsValidator.validate!

      StandardId::Engine.verify_host_cookie_encryption!(app)
      StandardId::Engine.warn_if_allowed_audiences_empty_in_production!
    end

    # Defensive check: StandardId's Web::SessionManager stores session tokens
    # in `cookies.encrypted[:session_token]` in addition to `session[:...]`.
    # If the host app is somehow missing a secret_key_base, encrypted cookies
    # fall back to plaintext and session tokens leak to the client. Rails 8
    # apps always have a secret_key_base, but this check catches misconfigured
    # test harnesses, custom boot sequences, and host apps that blank it out.
    #
    # We warn (not raise) to avoid breaking apps that intentionally short-
    # circuit boot (e.g., `assets:precompile` rake tasks with no secrets
    # available). A hard failure would be hostile to those workflows.
    def self.verify_host_cookie_encryption!(app)
      secret = app.respond_to?(:secret_key_base) ? app.secret_key_base : nil

      if secret.blank?
        Rails.logger.warn(
          "[StandardId] Host application has no secret_key_base configured. " \
          "Encrypted cookies will not be available and session tokens stored in " \
          "cookies.encrypted will be persisted in plaintext. Configure " \
          "Rails.application.credentials.secret_key_base (or ENV['SECRET_KEY_BASE']) " \
          "before running in production."
        )
      end
    end

    # Logs a production-only warning when no global audience allow-list is
    # configured. With `allowed_audiences` empty, the API token manager
    # skips decode-time aud enforcement, leaving cross-audience JWT replay
    # mitigation dependent on per-controller `AudienceVerification`
    # inclusion. Extracted to a module method so specs can exercise it
    # directly without booting a second Rails app.
    def self.warn_if_allowed_audiences_empty_in_production!
      return unless Rails.env.production?
      return if StandardId.config.oauth.allowed_audiences.present?

      Rails.logger.warn(
        "StandardId: config.oauth.allowed_audiences is empty in production — " \
        "JWT audience is not enforced globally. Set this to your expected " \
        "audiences (e.g., ['web', 'api']) to close cross-audience replay vectors."
      )
    end
  end
end
