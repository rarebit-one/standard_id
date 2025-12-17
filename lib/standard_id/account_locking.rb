module StandardId
  module AccountLocking
    extend ActiveSupport::Concern

    included do
      belongs_to :locked_by, polymorphic: true, optional: true
      belongs_to :unlocked_by, polymorphic: true, optional: true

      scope :locked, -> { where(locked: true) }
      scope :unlocked, -> { where(locked: false) }

      # Subscribe to events to enforce lock status
      # Lock check runs BEFORE status check (more restrictive first)
      StandardId::Events.subscribe(
        StandardId::Events::OAUTH_TOKEN_ISSUING,
        StandardId::Events::SESSION_CREATING,
        StandardId::Events::SESSION_VALIDATING
      ) do |event|
        account = event[:account]
        if account&.locked?
          raise StandardId::AccountLockedError.new(account)
        end
      end
    end

    def locked?
      locked == true
    end

    def unlocked?
      !locked?
    end

    def lock!(reason:, locked_by: nil)
      return true if locked?

      update!(
        locked: true,
        locked_at: Time.current,
        lock_reason: reason,
        locked_by: locked_by
      )

      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_LOCKED,
        account: self,
        reason: reason,
        locked_by: locked_by
      )

      true
    end

    def unlock!(unlocked_by: nil)
      return true if unlocked?

      update!(
        locked: false,
        unlocked_at: Time.current,
        unlocked_by: unlocked_by,
        lock_reason: nil
      )

      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_UNLOCKED,
        account: self,
        unlocked_by: unlocked_by
      )

      true
    end
  end
end
