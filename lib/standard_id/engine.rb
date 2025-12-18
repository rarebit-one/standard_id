module StandardId
  class Engine < ::Rails::Engine
    isolate_namespace StandardId

    config.after_initialize do
      if StandardId.config.events.enable_logging
        StandardId::Events::Subscribers::LoggingSubscriber.attach
      end

      if StandardId.config.events.enable_metrics
        StandardId::Events::Subscribers::AggregatedMetricsSubscriber.attach
      end
    end
  end
end
