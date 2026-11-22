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
    # On create only: a challenge read back from the database has no raw code
    # (see #code), and an update (#use!, the attempt counter) must not need one.
    validates :code, presence: true, on: :create
    validates :expires_at, presence: true

    scope :active, -> { where(used_at: nil).where("expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at <= ?", Time.current) }
    scope :used, -> { where.not(used_at: nil) }

    # HMAC-SHA256 of a one-time code under `secret_key_base`, which is all a
    # challenge stores of it (migration 20261122000000). It must be keyed: a
    # plain SHA256 of a 6-digit code is reversed by hashing all million
    # candidates. The versioned prefix domain-separates it from every other
    # digest keyed on the same secret.
    CODE_DIGEST_PREFIX = "standard_id.code_challenge.code_digest.v1:".freeze

    def self.digest_code(code, secret: StandardId::KeyedDigest.current_secret)
      StandardId::KeyedDigest.hmac_hexdigest("#{CODE_DIGEST_PREFIX}#{code}", secret:)
    end

    # Whether the host has run migration 20261122000000. Until then challenges
    # keep storing the plaintext code, exactly as before it existed.
    def self.code_digest_column?
      column_names.include?("code_digest")
    rescue ActiveRecord::ActiveRecordError
      false
    end

    # The raw code, on the instance that was created with it, and only there:
    # it reaches delivery (PASSWORDLESS_CODE_GENERATED's `code_challenge:`, the
    # built-in mailer, `Otp.issue(delivery: :manual).code`) on that in-memory
    # record. A challenge loaded from the database returns nil, or, for one
    # issued before the digest migration, the legacy plaintext column.
    def code
      @code || read_attribute(:code)
    end

    def code=(value)
      @code = value&.to_s

      if self.class.code_digest_column?
        self.code_digest = @code.presence && self.class.digest_code(@code)
      else
        super(@code)
      end
    end

    # Constant-time check of a submitted code. Accepts a digest written under
    # the current secret or any of `config.previous_secret_key_bases`; falls
    # back to the plaintext column only for a row that has no digest (issued
    # before the migration, or while it is pending).
    def code_matches?(candidate)
      candidate = candidate.to_s
      return false if candidate.empty?

      if has_attribute?(:code_digest) && code_digest.present?
        StandardId::KeyedDigest.secure_match?(
          code_digest,
          StandardId::KeyedDigest.candidates { |secret| self.class.digest_code(candidate, secret:) }
        )
      else
        legacy = read_attribute(:code).to_s
        legacy.present? && ActiveSupport::SecurityUtils.secure_compare(legacy, candidate)
      end
    end

    # Never serialise the code or its digest: event subscribers that write the
    # whole record (audit rows, logs) would otherwise store the raw code of a
    # just-issued challenge, which is exactly what the digest exists to avoid.
    def serializable_hash(options = nil)
      options = options&.dup || {}
      options[:except] = Array(options[:except]).map(&:to_s) | %w[code code_digest]
      super(options)
    end

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
