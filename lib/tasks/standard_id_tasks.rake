# Rake tasks for scheduled maintenance of StandardId tables.
#
# These tasks perform the underlying jobs synchronously (via `perform_now`)
# so they can be driven by any scheduler — cron, whenever, sidekiq-cron,
# solid_queue recurring tasks, etc. See docs/OPERATIONS.md for examples.
#
# Each task honours an optional GRACE_DAYS env var (default: 7) that controls
# how long after expiry a record must wait before deletion. The grace period
# avoids deleting rows that just expired and might still be referenced in
# in-flight requests.

namespace :standard_id do
  namespace :cleanup do
    desc "Delete expired sessions older than GRACE_DAYS (default 7)"
    task sessions: :environment do
      StandardId::CleanupExpiredSessionsJob.perform_now(
        grace_period_seconds: StandardId::RakeHelpers.grace_period_seconds
      )
    end

    desc "Delete expired/revoked refresh tokens older than GRACE_DAYS (default 7)"
    task refresh_tokens: :environment do
      StandardId::CleanupExpiredRefreshTokensJob.perform_now(
        grace_period_seconds: StandardId::RakeHelpers.grace_period_seconds
      )
    end

    desc "Delete expired/consumed authorization codes older than GRACE_DAYS (default 7). Consumed codes use a separate 1-day grace window (not env-configurable for now)."
    task authorization_codes: :environment do
      StandardId::CleanupExpiredAuthorizationCodesJob.perform_now(
        grace_period_seconds: StandardId::RakeHelpers.grace_period_seconds
      )
    end

    desc "Delete expired/used code challenges older than GRACE_DAYS (default 7). Used challenges use a separate 1-day grace window (not env-configurable for now)."
    task code_challenges: :environment do
      StandardId::CleanupExpiredCodeChallengesJob.perform_now(
        grace_period_seconds: StandardId::RakeHelpers.grace_period_seconds
      )
    end

    desc "Run all StandardId cleanup jobs with GRACE_DAYS (default 7)"
    task all: [:sessions, :refresh_tokens, :authorization_codes, :code_challenges]
  end
end

module StandardId
  module RakeHelpers
    module_function

    def grace_period_seconds
      days = Integer(ENV.fetch("GRACE_DAYS", "7"))
      days * 86_400
    end
  end
end
