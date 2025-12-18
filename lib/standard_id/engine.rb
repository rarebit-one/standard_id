module StandardId
  class Engine < ::Rails::Engine
    isolate_namespace StandardId

    config.after_initialize do
      if StandardId.config.events.enable_logging
        StandardId::Events::Subscribers::LoggingSubscriber.attach
      end

      if StandardId.config.events.enable_audit_log
        StandardId::Events::Subscribers::AuditLogSubscriber.attach
      end
    end
  end
end
