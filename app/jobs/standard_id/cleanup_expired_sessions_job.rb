module StandardId
  class CleanupExpiredSessionsJob < ApplicationJob
    queue_as :default

    DEFAULT_BATCH_SIZE = 1_000

    # Delete sessions that expired more than `grace_period_seconds` ago.
    # A grace period avoids deleting sessions that just expired and might
    # still be referenced in in-flight requests.
    # Accepts integer seconds for reliable ActiveJob serialization across all queue adapters.
    #
    # Refresh tokens reference their session (standard_id_refresh_tokens.session_id,
    # a foreign key with no ON DELETE action in the gem's migration), and
    # `delete_all` skips the model's `dependent: :nullify`, so a bare delete
    # failed the whole run once any expired session had a refresh token
    # (sidekick-web SIDEKICK-WEB-3K). Per batch, in one transaction:
    #
    # * An expired session that still has a LIVE refresh token (unrevoked,
    #   unexpired) is kept. Refresh tokens deliberately outlive their session's
    #   expiry — RefreshTokenFlow#validate_parent_session! checks revocation,
    #   not expiry, so refresh_token_lifetime alone governs how long a client
    #   stays signed in. Deleting the session would detach the token from it and
    #   lose "revoking this session ends its access"; revoking the token (what
    #   Session#destroy does) would sign the client out early. The session is
    #   collected on a later run, once its tokens are dead — at most
    #   refresh_token_lifetime later.
    # * Dead refresh tokens (revoked or expired) of the sessions being deleted
    #   are detached (`session_id` → NULL, the model's `dependent: :nullify`),
    #   not deleted: CleanupExpiredRefreshTokensJob removes them on its own
    #   window, and until then a replayed revoked token still triggers reuse
    #   detection.
    #
    # Batches (`in_batches`) keep each transaction and its locks small.
    def perform(grace_period_seconds: 7.days.to_i, batch_size: DEFAULT_BATCH_SIZE)
      cutoff = grace_period_seconds.seconds.ago
      deleted = 0

      StandardId::Session.where("expires_at < ?", cutoff).in_batches(of: batch_size) do |batch|
        deleted += delete_batch(batch.pluck(:id), cutoff)
      end

      Rails.logger.info("[StandardId] Cleaned up #{deleted} expired sessions older than #{cutoff}")
    end

    private

    def delete_batch(candidate_ids, cutoff)
      StandardId::Session.transaction do
        # Re-check under a row lock: a sign-in may have revived one of these
        # rows (OauthSessionPersistence reuses an expired, unrevoked device
        # session and bumps expires_at) or issued it a refresh token since the
        # batch was read. SKIP LOCKED leaves a row another transaction holds for
        # the next run. (SQLite ignores the lock clause; it serialises writers.)
        ids = StandardId::Session
          .where(id: candidate_ids)
          .where("expires_at < ?", cutoff)
          .where.not(id: live_refresh_tokens.select(:session_id))
          .lock("FOR UPDATE SKIP LOCKED")
          .pluck(:id)
        next 0 if ids.empty?

        StandardId::RefreshToken.where(session_id: ids).update_all(session_id: nil)
        StandardId::Session.where(id: ids).delete_all
      end
    end

    def live_refresh_tokens
      StandardId::RefreshToken.active.where.not(session_id: nil)
    end
  end
end
