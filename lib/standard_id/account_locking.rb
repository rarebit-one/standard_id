module StandardId
  module AccountLocking
    extend ActiveSupport::Concern

    # Guard against duplicate event subscriptions when AccountLocking is
    # included multiple times. The subscriber is process-wide, so one
    # registration is sufficient for the whole Ruby process.
    @subscribed = false

    class << self
      attr_accessor :subscribed
    end

    included do
      belongs_to :locked_by, polymorphic: true, optional: true
      belongs_to :unlocked_by, polymorphic: true, optional: true

      scope :locked, -> { where(locked: true) }
      scope :unlocked, -> { where(locked: false) }

      after_commit :emit_account_locked_event, on: :update, if: :just_locked?
      after_commit :emit_account_unlocked_event, on: :update, if: :just_unlocked?

      unless StandardId::AccountLocking.subscribed
        StandardId::AccountLocking.subscribed = true

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
    end

    def unlock!(unlocked_by: nil)
      return true if unlocked?

      update!(
        locked: false,
        unlocked_at: Time.current,
        unlocked_by: unlocked_by,
        lock_reason: nil
      )
    end

    private

    def just_locked?
      locked_previously_changed? && locked?
    end

    def just_unlocked?
      locked_previously_changed? && unlocked?
    end

    def emit_account_locked_event
      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_LOCKED,
        account: self,
        reason: lock_reason,
        locked_by:
      )
    end

    def emit_account_unlocked_event
      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_UNLOCKED,
        account: self,
        unlocked_by:
      )
    end
  end
end
