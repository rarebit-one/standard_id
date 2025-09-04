module StandardId
  class PasswordlessChallenge < ApplicationRecord
    self.table_name = "standard_id_passwordless_challenges"

    validates :connection_type, presence: true, inclusion: { in: %w[email sms] }
    validates :username, presence: true
    validates :code, presence: true, uniqueness: { scope: [:connection_type, :username, :expires_at] }
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
