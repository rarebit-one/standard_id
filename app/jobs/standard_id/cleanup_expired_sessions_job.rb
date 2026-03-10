module StandardId
  class CleanupExpiredSessionsJob < ApplicationJob
    queue_as :default

    # Delete sessions that expired more than `grace_period` ago.
    # A grace period avoids deleting sessions that just expired and might
    # still be referenced in in-flight requests.
    def perform(grace_period: 7.days)
      cutoff = grace_period.ago
      deleted = StandardId::Session.where("expires_at < ?", cutoff).delete_all
      Rails.logger.info("[StandardId] Cleaned up #{deleted} expired sessions older than #{cutoff}")
    end
  end
end
