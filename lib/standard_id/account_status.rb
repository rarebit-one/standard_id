module StandardId
  module AccountStatus
    extend ActiveSupport::Concern

    included do
      enum :status, { active: "active", inactive: "inactive" }, default: :active

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

      previous_status = status
      update!(status: :active, activated_at: Time.current)

      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_ACTIVATED,
        account: self,
        previous_status: previous_status
      )

      true
    end

    def deactivate!
      return true if inactive?

      previous_status = status
      update!(status: :inactive, deactivated_at: Time.current)

      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_DEACTIVATED,
        account: self,
        previous_status: previous_status
      )

      true
    end
  end
end
