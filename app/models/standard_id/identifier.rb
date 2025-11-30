module StandardId
  class Identifier < ApplicationRecord
    belongs_to :account, class_name: StandardId.config.account_class_name

    has_many :credentials, class_name: "StandardId::Credential", dependent: :restrict_with_exception

    scope :verified, -> { where.not(verified_at: nil) }
    scope :unverified, -> { where(verified_at: nil) }

    # Shared validations
    validates :value, presence: true, uniqueness: { scope: [:account_id, :type] }

    after_commit :mark_account_verified!, on: :update, if: :just_verified?
    after_commit :emit_identifier_created_event, on: :create

    def verified?
      verified_at.present?
    end

    def verify!
      update!(verified_at: Time.current)
      emit_verification_succeeded
    end

    def unverify!
      update!(verified_at: nil)
    end

    private

    def just_verified?
      saved_change_to_verified_at? && verified_at.present?
    end

    def mark_account_verified!
      return if account.nil?

      return unless account.has_attribute?(:verified)
      return unless account.has_attribute?(:verified_at)

      account.update!(verified: true, verified_at: Time.current)
      emit_account_verified
    end

    def emit_identifier_created_event
      StandardId::Events.publish(
        StandardId::Events::IDENTIFIER_CREATED,
        identifier: self,
        account: account
      )
    end

    def emit_verification_succeeded
      StandardId::Events.publish(
        StandardId::Events::IDENTIFIER_VERIFICATION_SUCCEEDED,
        identifier: self,
        account: account,
        verified_at: verified_at
      )
    end

    def emit_account_verified
      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_VERIFIED,
        account: account,
        verified_via: type.demodulize.underscore.gsub("_identifier", "")
      )
    end
  end
end
