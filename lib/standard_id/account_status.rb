module StandardId
  module AccountStatus
    extend ActiveSupport::Concern

    # Guard against duplicate event subscriptions when AccountStatus is
    # included multiple times (Rails reload, re-include on subclass, re-including
    # the concern from host app specs, etc). The subscribers are process-wide,
    # so one registration is sufficient for the whole Ruby process.
    @subscribed = false

    class << self
      attr_accessor :subscribed
    end

    # The configured enum key for a deactivated account (`config.inactive_account_status`).
    def self.inactive_status
      StandardId.config.inactive_account_status.to_s.presence&.to_sym || :inactive
    end

    included do
      # The deactivated key is read from config ONCE, here, when the concern is
      # included: a host whose column already says "suspended" declares
      # `c.inactive_account_status = :suspended` and gets `suspended?`, the
      # `suspended` scope and status "suspended", with no enum value to rename.
      inactive_status = StandardId::AccountStatus.inactive_status
      class_attribute :standard_id_inactive_status, instance_writer: false, default: inactive_status

      enum :status, { active: "active", inactive_status => inactive_status.to_s }, default: :active
      alias_method :inactive?, :"#{inactive_status}?" unless inactive_status == :inactive

      after_commit :emit_account_status_changed_event, on: :update, if: :status_previously_changed?

      unless StandardId::AccountStatus.subscribed
        StandardId::AccountStatus.subscribed = true

        StandardId::Events.subscribe(
          StandardId::Events::OAUTH_TOKEN_ISSUING,
          StandardId::Events::SESSION_CREATING,
          StandardId::Events::SESSION_VALIDATING
        ) do |event|
          account = event[:account]
          if StandardId::AccountStatus.deactivated?(account)
            raise StandardId::AccountDeactivatedError, StandardId::AccountStatus.deactivated_message(account)
          end
        end
      end
    end

    # Whether +account+ is in its configured deactivated status. False for nil
    # and for a model that does not include this concern.
    def self.deactivated?(account)
      return false unless account.respond_to?(:standard_id_inactive_status)

      account.public_send(:"#{account.standard_id_inactive_status}?")
    end

    # "Account is deactivated" for the default key; "Account is suspended" (the
    # host's own word) for a renamed one.
    def self.deactivated_message(account)
      status = account.standard_id_inactive_status
      status == :inactive ? "Account is deactivated" : "Account is #{status}"
    end

    def activate!
      return true if active?

      attributes = { status: :active }
      attributes[:activated_at] = Time.current if has_attribute?(:activated_at)
      update!(**attributes)
    end

    def deactivate!
      return true if standard_id_deactivated?

      attributes = { status: standard_id_inactive_status }
      attributes[:deactivated_at] = Time.current if has_attribute?(:deactivated_at)
      update!(**attributes)
    end

    private

    def standard_id_deactivated?
      StandardId::AccountStatus.deactivated?(self)
    end

    def emit_account_status_changed_event
      event = standard_id_deactivated? ? StandardId::Events::ACCOUNT_DEACTIVATED : StandardId::Events::ACCOUNT_ACTIVATED
      StandardId::Events.publish(
        event,
        account: self,
        previous_status: status_previously_was
      )
    end
  end
end
