require "bcrypt"

module StandardId
  class Session < ApplicationRecord
    self.table_name = "standard_id_sessions"

    belongs_to :account, class_name: StandardId.config.account_class_name
    # See StandardId::AssociationStrictLoading — resolves to no option at all
    # unless config.association_strict_loading is set.
    has_many :refresh_tokens, class_name: "StandardId::RefreshToken", dependent: :nullify,
             **StandardId::AssociationStrictLoading.option

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

    # Counts returned by the bulk-revocation class methods. Callers use these to
    # emit their own aggregate event (see
    # StandardId::Api::Oauth::RevocationsController#emit_token_revoked) — the
    # bulk methods deliberately do NOT publish an aggregate themselves.
    RevocationResult = Struct.new(:sessions_revoked, :refresh_tokens_revoked, keyword_init: true)

    # Revoke every not-yet-revoked session for an account, cascading to refresh
    # tokens, in two set-based UPDATEs.
    #
    # Honours the current scope, so callers narrow as they need:
    #
    #   StandardId::Session.revoke_all_for!(account, reason: "password_reset")
    #   StandardId::DeviceSession.active.revoke_all_for!(account, reason: "logout")
    #
    # Why this exists rather than `sessions.each(&:revoke!)`: the loop is O(N)
    # UPDATEs plus O(N) refresh-token cascades, and the call sites are admin bulk
    # actions and password resets.
    #
    # Events: one SESSION_REVOKED per revoked session, never a single aggregate —
    # subscribers must not need a second code path for bulk revocation. Each is
    # published individually and individually rescued (see .revoke_sessions!).
    #
    # @param account [ActiveRecord::Base, String, Integer] the account, or its id
    # @param reason [String, nil] carried on each SESSION_REVOKED event
    # @return [RevocationResult] counts of revoked sessions and refresh tokens
    def self.revoke_all_for!(account, reason: nil)
      account_id = account.is_a?(ActiveRecord::Base) ? account.id : account
      sessions = where(account_id: account_id).where(revoked_at: nil).to_a
      account_record = account.is_a?(ActiveRecord::Base) ? account : nil

      revoke_sessions!(sessions, account: account_record, reason: reason)
    end

    # Set-based revocation of an explicit collection of sessions.
    #
    # Bulk-revoke in two queries (one UPDATE per table) instead of issuing
    # session.revoke! per row, which would be O(N) UPDATEs plus another O(N)
    # cascades to refresh_tokens.
    #
    # Tradeoff: update_all skips ActiveRecord callbacks, so the per-row
    # SESSION_REVOKED event emitted by #revoke! (via its after_commit) does not
    # fire automatically. We re-emit it explicitly below so audit-trail
    # subscribers (account status/locking, etc.) still see one event per revoked
    # session — the semantics are preserved, only the SQL shape has changed.
    #
    # @param sessions [Enumerable<StandardId::Session>] sessions to revoke; all
    #   must belong to the same account
    # @param account [ActiveRecord::Base, nil] the shared account, when the
    #   caller already has it loaded. Passed through rather than read per row:
    #   `session.account` would issue N extra SELECTs. Falls back to
    #   `sessions.first.account`.
    # @param reason [String, nil] carried on each SESSION_REVOKED event
    # @return [RevocationResult] counts of revoked sessions and refresh tokens
    def self.revoke_sessions!(sessions, account: nil, reason: nil)
      sessions = sessions.to_a
      return RevocationResult.new(sessions_revoked: 0, refresh_tokens_revoked: 0) if sessions.empty?

      now = Time.current
      session_ids = sessions.map(&:id)
      refresh_tokens_revoked = 0

      ActiveRecord::Base.transaction do
        StandardId::Session.where(id: session_ids).update_all(revoked_at: now)
        refresh_tokens_revoked = StandardId::RefreshToken
          .where(session_id: session_ids, revoked_at: nil)
          .update_all(revoked_at: now)
      end

      publish_session_revocations(sessions, account: account, reason: reason, now: now)

      RevocationResult.new(
        sessions_revoked: sessions.size,
        refresh_tokens_revoked: refresh_tokens_revoked
      )
    end

    # DB state is already committed by the time this runs; event publishing is
    # best-effort audit emission. A failing subscriber must not short-circuit the
    # loop and leave later sessions without their SESSION_REVOKED event, which
    # would permanently desync audit-trail consumers from the DB.
    def self.publish_session_revocations(sessions, account:, reason:, now:)
      shared_account = account || sessions.first.account

      sessions.each do |session|
        session.revoked_at = now

        begin
          StandardId::Events.publish(
            StandardId::Events::SESSION_REVOKED,
            session: session,
            account: shared_account,
            reason: reason
          )
        rescue StandardError => e
          # The rescue exists so a failing subscriber cannot short-circuit the
          # loop. Logging must therefore not be able to raise either, or the
          # guarantee evaporates on the first bad log call: StandardId.logger is
          # a memoized `config.logger || Rails.logger`, so whatever the first
          # reader saw is what every later caller gets — including a value that
          # is not a logger at all.
          logger = StandardId.logger
          next unless logger.respond_to?(:error)

          logger.error(
            "[StandardId::Session] Failed to publish SESSION_REVOKED " \
            "for session #{session.id}: #{e.class}: #{e.message}"
          )
        end
      end
    end
    private_class_method :publish_session_revocations

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
