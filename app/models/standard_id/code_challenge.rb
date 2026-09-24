module StandardId
  class CodeChallenge < ApplicationRecord
    # Transient (not persisted): set by the built-in PasswordlessDeliverySubscriber
    # once it has enqueued the email, so the passwordless strategy can report
    # PASSWORDLESS_CODE_SENT truthfully.
    attr_accessor :built_in_delivered
    self.table_name = "standard_id_code_challenges"

    # Well-known realms used by the engine itself. Host apps may create
    # challenges in any realm (see StandardId::Otp) — realm is a free-form
    # string that partitions challenges by purpose (e.g. "authentication",
    # "verification", "custom_widget"). Only presence is validated so
    # consumers can define their own realms without the engine knowing.
    REALMS = %w[authentication verification].freeze
    CHANNELS = %w[email sms].freeze

    validates :realm, presence: true
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
