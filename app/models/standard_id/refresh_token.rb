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
      update!(revoked_at: Time.current) unless revoked?
    end

    # Revoke this token and all tokens in the same family chain.
    # A "family" is all tokens linked via previous_token_id.
    # Only revokes tokens that aren't already revoked, preserving historical
    # revoked_at timestamps for audit purposes.
    def revoke_family!
      family_tokens.where(revoked_at: nil).update_all(revoked_at: Time.current)
    end

    # Max depth guard to prevent unbounded traversal in case of
    # corrupted data or extremely long-lived token chains.
    MAX_FAMILY_DEPTH = 50

    private

    # Find the root of this token's family and return all descendants.
    # Uses iterative queries (one per generation) bounded by MAX_FAMILY_DEPTH.
    # For typical token chain lengths (<10) this is fine; a recursive CTE
    # would collapse to a single query if performance becomes a concern.
    def family_tokens
      root = self
      depth = 0
      while root.previous_token.present? && depth < MAX_FAMILY_DEPTH
        root = root.previous_token
        depth += 1
      end

      self.class.where(id: collect_family_ids(root.id))
    end

    def collect_family_ids(root_id)
      ids = [root_id]
      current_ids = [root_id]
      depth = 0

      while depth < MAX_FAMILY_DEPTH
        next_ids = self.class.where(previous_token_id: current_ids).pluck(:id)
        break if next_ids.empty?

        ids.concat(next_ids)
        current_ids = next_ids
        depth += 1
      end

      ids
    end
  end
end
