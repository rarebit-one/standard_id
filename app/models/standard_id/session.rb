require "bcrypt"

module StandardId
  class Session < ApplicationRecord
    self.table_name = "standard_id_sessions"

    belongs_to :account, class_name: StandardId.config.account_class_name
    has_many :refresh_tokens, class_name: "StandardId::RefreshToken", dependent: :nullify

    before_destroy :revoke_active_refresh_tokens, prepend: true

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
    after_commit :emit_session_revoked_event, on: :update, if: :just_revoked?

    def active?
      !revoked? && !expired?
    end

    def expired?
      expires_at <= Time.current
    end

    def revoked?
      revoked_at.present?
    end

    def revoke!(reason: nil)
      @reason = reason
      transaction do
        update!(revoked_at: Time.current)
        # Cascade revocation to refresh tokens. Uses update_all for efficiency;
        # intentionally skips updated_at since revocation is tracked via revoked_at.
        refresh_tokens.active.update_all(revoked_at: Time.current)
      end
    end

    private

    def generate_token
      @token ||= SecureRandom.urlsafe_base64(32)
    end

    def generate_token_digest
      configured_cost = StandardId.config.session.token_digest_cost
      self.token_digest =
        if configured_cost.nil?
          BCrypt::Password.create(token)
        else
          cost = configured_cost.clamp(BCrypt::Engine::MIN_COST, BCrypt::Engine::MAX_COST)
          BCrypt::Password.create(token, cost: cost)
        end
    end

    def generate_lookup_hash
      self.lookup_hash = Digest::SHA256.hexdigest("#{token}:#{Rails.configuration.secret_key_base}")
    end

    # Revoke any still-active refresh tokens before the session row is deleted,
    # so tokens don't become orphaned but usable.
    def revoke_active_refresh_tokens
      refresh_tokens.active.update_all(revoked_at: Time.current)
    end

    def just_revoked?
      saved_change_to_revoked_at? && revoked?
    end

    def emit_session_revoked_event
      StandardId::Events.publish(
        StandardId::Events::SESSION_REVOKED,
        session: self,
        account:,
        reason: @reason
      )
    end
  end
end
