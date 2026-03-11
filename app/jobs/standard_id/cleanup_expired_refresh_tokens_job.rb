module StandardId
  class CleanupExpiredRefreshTokensJob < ApplicationJob
    queue_as :default

    # Delete refresh tokens that expired or were revoked more than
    # `grace_period_seconds` ago.
    # Accepts integer seconds for reliable ActiveJob serialization across all queue adapters.
    def perform(grace_period_seconds: 7.days.to_i)
      cutoff = grace_period_seconds.seconds.ago
      deleted = StandardId::RefreshToken
        .where("expires_at < :cutoff OR revoked_at < :cutoff", cutoff: cutoff)
        .delete_all
      Rails.logger.info("[StandardId] Cleaned up #{deleted} expired/revoked refresh tokens older than #{cutoff}")
    end
  end
end
