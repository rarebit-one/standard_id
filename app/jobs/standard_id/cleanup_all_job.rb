module StandardId
  # Runs all four expired-row cleanup jobs inline, in one job.
  #
  # Schedule this ONE job instead of the four individual ones when you want a
  # single recurring entry — typically so the schedule carries one cron
  # monitor (Sentry, Honeybadger, …) rather than four. Subclass it in the host
  # to attach the monitor:
  #
  #   # app/jobs/standard_id_cleanup_job.rb
  #   class StandardIdCleanupJob < StandardId::CleanupAllJob
  #     include Sentry::Cron::MonitorCheckIns
  #     sentry_monitor_check_ins slug: "standard-id-cleanup",
  #       monitor_config: Sentry::Cron::MonitorConfig.from_crontab("7 * * * *")
  #   end
  #
  # One table's DELETE failing (a lock timeout, say) does not skip the others;
  # the first error is re-raised once all four have run, so the run still
  # fails its cron check-in and lands in the queue's failed executions.
  #
  # Each job keeps its default grace windows (see README "Scheduled
  # Maintenance"); retention is bounded by those, not by the cadence.
  class CleanupAllJob < ApplicationJob
    queue_as :default

    # @return [Array<Class>] the cleanup jobs run, in order
    def self.jobs
      [
        StandardId::CleanupExpiredSessionsJob,
        StandardId::CleanupExpiredRefreshTokensJob,
        StandardId::CleanupExpiredAuthorizationCodesJob,
        StandardId::CleanupExpiredCodeChallengesJob
      ]
    end

    def perform
      errors = self.class.jobs.filter_map do |job|
        job.perform_now
        nil
      rescue StandardError => e
        Rails.logger.warn("[StandardId] #{job.name} failed: #{e.class}: #{e.message}")
        e
      end
      raise errors.first if errors.any?
    end
  end
end
