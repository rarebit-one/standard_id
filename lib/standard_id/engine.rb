module StandardId
  class Engine < ::Rails::Engine
    isolate_namespace StandardId

    config.after_initialize do
      if StandardId.config.events.enable_logging
        StandardId::Events::Subscribers::LoggingSubscriber.attach
      end

      StandardId::Events::Subscribers::AccountStatusSubscriber.attach
      StandardId::Events::Subscribers::AccountLockingSubscriber.attach

      if StandardId.config.issuer.blank?
        Rails.logger.warn("[StandardId] No issuer configured. JWT tokens will not include or verify the 'iss' claim. " \
                          "Set StandardId.config.issuer in your initializer for production use.")
      end
    end
  end
end
