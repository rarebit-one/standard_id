module StandardId
  class CleanupExpiredAuthorizationCodesJob < ApplicationJob
    queue_as :default

    # Delete OAuth authorization codes that are either expired or consumed
    # beyond the respective grace periods.
    #
    # Authorization codes are single-use and short-lived (OAuth 2.1 recommends
    # a lifetime under 10 minutes). Two grace windows apply:
    #
    # - `grace_period_seconds` (default 7 days): how long expired-but-unused
    #   codes are retained after `expires_at`. Matches the sessions/refresh-
    #   token cleanup windows so operators only have to reason about one
    #   default.
    # - `consumed_grace_period_seconds` (default 1 day): how long consumed
    #   codes are retained after `consumed_at`. Used codes are useless after
    #   redemption, so they're pruned faster — keeping them briefly only
    #   helps with replay-attack forensics in the immediate aftermath of a
    #   redemption.
    #
    # Accepts integer seconds for reliable ActiveJob serialization across all
    # queue adapters.
    def perform(grace_period_seconds: 7.days.to_i, consumed_grace_period_seconds: 1.day.to_i)
      expired_cutoff = grace_period_seconds.seconds.ago
      consumed_cutoff = consumed_grace_period_seconds.seconds.ago

      # The two windows govern disjoint sets of rows:
      #   - Unconsumed codes: ruled by `expires_at < expired_cutoff`.
      #   - Consumed codes:   ruled by `consumed_at < consumed_cutoff`.
      #
      # A naive `expires_at < :expired_cutoff OR consumed_at < :consumed_cutoff`
      # would let the expired arm delete a consumed-12-hours-ago row whose
      # `expires_at` sits 8 days in the past — defeating the consumed grace
      # window's whole purpose. Scoping the expired clause to `consumed_at IS
      # NULL` keeps consumed rows under the consumed window exclusively.
      deleted = StandardId::AuthorizationCode
        .where(
          "(expires_at < :expired_cutoff AND consumed_at IS NULL) " \
            "OR consumed_at < :consumed_cutoff",
          expired_cutoff: expired_cutoff,
          consumed_cutoff: consumed_cutoff
        )
        .delete_all

      Rails.logger.info(
        "[StandardId] Cleaned up #{deleted} authorization codes " \
        "(expired before #{expired_cutoff}, consumed before #{consumed_cutoff})"
      )
    end
  end
end
