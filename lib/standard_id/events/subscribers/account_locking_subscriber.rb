module StandardId
  module Events
    module Subscribers
      class AccountLockingSubscriber < Base
        subscribe_to StandardId::Events::ACCOUNT_LOCKED

        def call(event)
          account = event[:account]
          active_sessions = account.sessions.active
          active_sessions.find_each do |session|
            session.revoke!(reason: "account_locked")
          end
        end
      end
    end
  end
end
