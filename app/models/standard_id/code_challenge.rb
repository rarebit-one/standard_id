module StandardId
  class CodeChallenge < ApplicationRecord
    self.table_name = "standard_id_code_challenges"

    REALMS = %w[authentication verify_email verify_phone account_confirmation unlock_account].freeze
    CHANNELS = %w[email sms].freeze

    validates :realm, presence: true, inclusion: { in: REALMS }
    validates :channel, presence: true, inclusion: { in: CHANNELS }
    validates :target, presence: true
    validates :code, presence: true
    validates :expires_at, presence: true

    scope :active, -> { where(used_at: nil).where("expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at <= ?", Time.current) }
    scope :used, -> { where.not(used_at: nil) }

    def expired?
      expires_at <= Time.current
    end

    def used?
      used_at.present?
    end

    def active?
      !expired? && !used?
    end

    def use!
      update!(used_at: Time.current)
    end
  end
end
