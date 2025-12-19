module StandardId
  module AccountStatus
    extend ActiveSupport::Concern

    included do
      enum :status, { active: "active", inactive: "inactive" }, default: :active

      after_commit :emit_account_status_changed_event, on: :update, if: :status_previously_changed?

      StandardId::Events.subscribe(
        StandardId::Events::OAUTH_TOKEN_ISSUING,
        StandardId::Events::SESSION_CREATING,
        StandardId::Events::SESSION_VALIDATING
      ) do |event|
        account = event[:account]
        if account&.inactive?
          raise StandardId::AccountDeactivatedError, "Account is deactivated"
        end
      end
    end

    def activate!
      return true if active?

      update!(status: :active, activated_at: Time.current)
    end

    def deactivate!
      return true if inactive?

      update!(status: :inactive, deactivated_at: Time.current)
    end

    private

    def emit_account_status_changed_event
      event = inactive? ? StandardId::Events::ACCOUNT_DEACTIVATED : StandardId::Events::ACCOUNT_ACTIVATED
      StandardId::Events.publish(
        event,
        account: self,
        previous_status: status_previously_was
      )
    end
  end
end
