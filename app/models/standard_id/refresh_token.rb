module StandardId
  class RefreshToken < ApplicationRecord
    self.table_name = "standard_id_refresh_tokens"

    belongs_to :account, class_name: StandardId.config.account_class_name
    belongs_to :session, class_name: "StandardId::Session", optional: true
    belongs_to :previous_token, class_name: "StandardId::RefreshToken", optional: true
    # The ClientApplication this token was issued to, when the grant's client_id
    # named one (migration 20261020000000). NULL for tokens whose client_id is
    # not an application (social sign-in refreshes as the provider's name) and
    # for rows minted before the column existed. No FK on purpose: a deleted
    # application has to stay detectable as "gone" (see #client_application_live?).
    belongs_to :client_application, class_name: "StandardId::ClientApplication", optional: true

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

    # Whether the host has run migration 20261020000000. Until then the gem
    # neither writes nor reads the binding.
    def self.client_binding_column?
      column_names.include?("client_application_id")
    rescue ActiveRecord::ActiveRecordError
      false
    end

    # false once the application this token is bound to has been deactivated
    # or deleted. An unbound token (NULL, or the column not yet migrated) is
    # live by this measure: there is no application whose fate it shares.
    #
    # Same definition as ClientApplication#active? (`active` AND no
    # `deactivated_at`), not the `active` scope alone, so this and the refresh
    # grant can never disagree about a row whose two fields drifted apart.
    def client_application_live?
      return true unless self.class.client_binding_column?
      return true if client_application_id.nil?

      StandardId::ClientApplication.where(id: client_application_id, active: true, deactivated_at: nil).exists?
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
