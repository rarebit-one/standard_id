module StandardId
  class Engine < ::Rails::Engine
    isolate_namespace StandardId

    config.after_initialize do
      if StandardId.config.events.enable_logging
        StandardId::Events::Subscribers::LoggingSubscriber.attach
      end

      StandardId::Events::Subscribers::AccountStatusSubscriber.attach
    end
  end
end
