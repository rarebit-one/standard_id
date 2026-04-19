module StandardId
  class RefreshToken < ApplicationRecord
    self.table_name = "standard_id_refresh_tokens"

    belongs_to :account, class_name: StandardId.config.account_class_name
    belongs_to :session, class_name: "StandardId::Session", optional: true
    belongs_to :previous_token, class_name: "StandardId::RefreshToken", optional: true

    scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at <= ?", Time.current) }
    scope :revoked, -> { where.not(revoked_at: nil) }

    validates :token_digest, presence: true, uniqueness: true
    validates :expires_at, presence: true

    def self.digest_for(jti)
      Digest::SHA256.hexdigest(jti)
    end

    def self.find_by_jti(jti)
      find_by(token_digest: digest_for(jti))
    end

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
      rows = self.class.where(id: id, revoked_at: nil).update_all(revoked_at: Time.current)
      reload if rows > 0
    end

    # Revoke this token and all tokens in the same family chain.
    # A "family" is all tokens linked via previous_token_id.
    # Only revokes tokens that aren't already revoked, preserving historical
    # revoked_at timestamps for audit purposes.
    def revoke_family!
      family_tokens.where(revoked_at: nil).update_all(revoked_at: Time.current)
    end

    private

    # Collect every token in this token's family (all ancestors + all
    # descendants reachable via previous_token_id) in a single recursive
    # CTE. Previously we walked the chain in Ruby with one query per
    # generation — fine for small families, O(depth) under reuse-detection
    # storms. The CTE is one round trip.
    #
    # `UNION` (not `UNION ALL`) deduplicates against the full accumulator
    # at each step — so a row already emitted earlier in the traversal is
    # skipped, preventing infinite loops on cyclic data. Supported by
    # PostgreSQL, SQLite 3.8+, and MySQL 8+.
    def family_tokens
      table = self.class.quoted_table_name
      sql = <<~SQL.squish
        WITH RECURSIVE family AS (
          SELECT id, previous_token_id FROM #{table} WHERE id = :id
          UNION
          SELECT rt.id, rt.previous_token_id
          FROM #{table} rt
          JOIN family f ON rt.id = f.previous_token_id OR rt.previous_token_id = f.id
        )
        SELECT id FROM family
      SQL
      family_ids = self.class.connection.select_values(self.class.sanitize_sql([sql, { id: id }]))
      self.class.where(id: family_ids)
    end
  end
end
