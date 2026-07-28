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

    # Authenticate an opaque session token.
    #
    # `by_token` is NOT authentication on its own: it matches the SHA256
    # `lookup_hash`, which exists only to find the candidate row from an
    # indexed column. The credential is `token_digest` (see #authenticate_token
    # for the two schemes it may hold), and every consumer previously had to
    # remember to verify it by hand — and to rescue BCrypt::Errors::InvalidHash.
    # This is that step, done once, here.
    #
    # Honours the current scope, so callers keep their own filters:
    #
    #   StandardId::Session.api_compatible.active.authenticate_by_token(token)
    #
    # @param token [String, nil] the raw token presented by the client
    # @return [StandardId::Session, nil] the session, or nil when the token is
    #   blank, matches no row, or fails the digest verification
    def self.authenticate_by_token(token)
      return nil if token.blank?

      session = by_token(token).first
      return nil if session.nil?

      session.authenticate_token(token) ? session : nil
    end

    # Keyed digest of an opaque session token — the default scheme.
    #
    # HMAC-SHA256 under `secret_key_base`, domain-separated from `lookup_hash`
    # by both construction (HMAC vs plain SHA256) and an explicit versioned
    # prefix, so the two stored values can never coincide even though both
    # derive from the same token and secret.
    #
    # Why not BCrypt (which this was, and which `token_digest_cost` still
    # selects): BCrypt's cost factor exists to make brute-force of a LOW-entropy
    # secret expensive. Session tokens are `SecureRandom.urlsafe_base64(32)` —
    # 256 bits — so guessing one is infeasible regardless of how fast the hash
    # is, and the stretching bought nothing while costing a measured ~181 ms of
    # CPU on EVERY authenticated request (cost 12). That is the same reasoning
    # under which `RefreshToken` digests with plain SHA256 and `lookup_hash`
    # with SHA256; this brings session tokens in line with both.
    DIGEST_PREFIX = "standard_id.session.token_digest.v1:".freeze

    def self.hmac_token_digest(token)
      OpenSSL::HMAC.hexdigest(
        "SHA256", Rails.configuration.secret_key_base, "#{DIGEST_PREFIX}#{token}"
      )
    end

    # Timing-safe verification of `token` against this session's stored digest.
    #
    # Handles BOTH schemes, because digests written before the HMAC default —
    # and any written since by an app that sets `token_digest_cost` — are
    # BCrypt. A BCrypt digest is self-identifying by its `$2<x>$` prefix, so the
    # scheme is read off the stored value rather than off configuration; that
    # way a config change never strands existing sessions, and no rewrite of
    # stored digests is needed. Both branches end in a constant-time compare, so
    # the response time carries no information about how much of the digest
    # matched.
    #
    # @return [Boolean] false for a blank or malformed digest — never raises.
    def authenticate_token(token)
      return false if token.blank? || token_digest.blank?

      if token_digest.start_with?("$2")
        stored = BCrypt::Password.new(token_digest)
        ActiveSupport::SecurityUtils.secure_compare(
          stored.to_s,
          BCrypt::Engine.hash_secret(token, stored.salt)
        )
      else
        ActiveSupport::SecurityUtils.secure_compare(
          token_digest, self.class.hmac_token_digest(token)
        )
      end
    rescue BCrypt::Errors::InvalidHash, BCrypt::Errors::InvalidSalt
      false
    end

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

    # HMAC by default; BCrypt only when an app explicitly asks for it by setting
    # `token_digest_cost`. That inverts the previous default (BCrypt at
    # bcrypt-ruby's cost 12) — see .hmac_token_digest for why — while leaving
    # the escape hatch meaning exactly what it says for anyone who set it
    # deliberately. Existing rows are untouched either way: #authenticate_token
    # reads the scheme off the stored digest, not off this config.
    def generate_token_digest
      configured_cost = StandardId.config.session.token_digest_cost
      self.token_digest =
        if configured_cost.nil?
          self.class.hmac_token_digest(token)
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
