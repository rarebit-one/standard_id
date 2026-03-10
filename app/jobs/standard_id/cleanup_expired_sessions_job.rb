module StandardId
  class CleanupExpiredSessionsJob < ApplicationJob
    queue_as :default

    # Delete sessions that expired more than `grace_period_seconds` ago.
    # A grace period avoids deleting sessions that just expired and might
    # still be referenced in in-flight requests.
    # Accepts integer seconds for reliable ActiveJob serialization across all queue adapters.
    def perform(grace_period_seconds: 7.days.to_i)
      cutoff = grace_period_seconds.seconds.ago
      deleted = StandardId::Session.where("expires_at < ?", cutoff).delete_all
      Rails.logger.info("[StandardId] Cleaned up #{deleted} expired sessions older than #{cutoff}")
    end
  end
end
