module StandardId
  module Events
    module Subscribers
      class AccountStatusSubscriber < Base
        subscribe_to StandardId::Events::ACCOUNT_DEACTIVATED

        def call(event)
          account = event[:account]
          active_sessions = account.sessions.active
          active_sessions.find_each do |session|
            session.revoke!(reason: "account_deactivated")
          end
        end
      end
    end
  end
end
