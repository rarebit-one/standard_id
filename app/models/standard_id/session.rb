require "bcrypt"

module StandardId
  class Session < ApplicationRecord
    self.table_name = "standard_id_sessions"

    belongs_to :account, class_name: StandardId.config.account_class_name

    scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at <= ?", Time.current) }
    scope :revoked, -> { where.not(revoked_at: nil) }

    scope :api_compatible, -> { where(type: ["StandardId::DeviceSession", "StandardId::ServiceSession"]) }
    scope :by_token, ->(token) {
      lookup_hash = Digest::SHA256.hexdigest("#{token}:#{Rails.configuration.secret_key_base}")
      where(lookup_hash:)
    }

    attr_reader :token

    before_validation :generate_token, :generate_token_digest, :generate_lookup_hash, on: :create


    def active?
      !revoked? && !expired?
    end

    def expired?
      expires_at <= Time.current
    end

    def revoked?
      revoked_at.present?
    end

    def revoke!
      update!(revoked_at: Time.current)
    end

    private

    def generate_token
      @token ||= SecureRandom.urlsafe_base64(32)
    end

    def generate_token_digest
      self.token_digest = BCrypt::Password.create(token)
    end

    def generate_lookup_hash
      self.lookup_hash = Digest::SHA256.hexdigest("#{token}:#{Rails.configuration.secret_key_base}")
    end
  end
end
