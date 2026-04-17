module StandardId
  class CleanupExpiredCodeChallengesJob < ApplicationJob
    queue_as :default

    # Delete code challenges (OTP records) that are either expired or used
    # beyond the respective grace periods.
    #
    # Code challenges back passwordless/OTP flows: rows are short-lived and
    # single-use. Two grace windows apply:
    #
    # - `grace_period_seconds` (default 7 days): how long expired-but-unused
    #   challenges are retained after `expires_at`. Matches the sessions/
    #   refresh-token cleanup windows for operational consistency.
    # - `used_grace_period_seconds` (default 1 day): how long used challenges
    #   are retained after `used_at`. A used OTP is useless after redemption,
    #   so prune faster — the short tail only helps with replay-attack
    #   forensics immediately after use.
    #
    # Accepts integer seconds for reliable ActiveJob serialization across all
    # queue adapters.
    def perform(grace_period_seconds: 7.days.to_i, used_grace_period_seconds: 1.day.to_i)
      expired_cutoff = grace_period_seconds.seconds.ago
      used_cutoff = used_grace_period_seconds.seconds.ago

      deleted = StandardId::CodeChallenge
        .where("expires_at < :expired_cutoff OR used_at < :used_cutoff",
               expired_cutoff: expired_cutoff, used_cutoff: used_cutoff)
        .delete_all

      Rails.logger.info(
        "[StandardId] Cleaned up #{deleted} code challenges " \
        "(expired before #{expired_cutoff}, used before #{used_cutoff})"
      )
    end
  end
end
