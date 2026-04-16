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

      if StandardId.config.issuer.blank?
        Rails.logger.warn("[StandardId] No issuer configured. JWT tokens will not include or verify the 'iss' claim. " \
                          "Set StandardId.config.issuer in your initializer for production use.")
      end

      StandardId::Engine.verify_host_cookie_encryption!(app)
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
  end
end
