module StandardId
  class Engine < ::Rails::Engine
    isolate_namespace StandardId

    config.after_initialize do
      if StandardId.config.events.enable_logging
        StandardId::Events::Subscribers::LoggingSubscriber.attach
      end

      StandardId::Events::Subscribers::AccountStatusSubscriber.attach if StandardId.config.account_status.revoke_sessions_on_deactivate
      StandardId::Events::Subscribers::AccountLockingSubscriber.attach if StandardId.config.account_locking.revoke_sessions_on_lock
    end
  end
end
