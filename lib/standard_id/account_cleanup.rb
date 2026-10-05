module StandardId
  # Removes an account that was created during the current request and then
  # refused sign-in (by a lifecycle hook or the login-method policy), so the
  # refusal does not leave an orphaned account behind.
  #
  # Every association read goes through `.strict_loading(false)`: the account
  # was built in this request, so none of its associations are loaded, and a
  # host running `strict_loading_by_default = true` (most consumers) would
  # otherwise raise StrictLoadingViolationError on `account.sessions` — turning
  # a clean rejection of a new signup into a 500 and leaving the orphaned
  # account behind. Relation-level `strict_loading(false)` also covers the
  # records it loads, so `identifier.credentials` below is safe too.
  #
  # The account is visible to other requests from the moment it is created,
  # so a concurrent sign-in can find it (by email) and sign in to it before
  # this request is refused. The removal therefore takes a row lock on the
  # account and skips it when the account has been adopted — it has an
  # active session or an unrevoked refresh token, which this request's own
  # rejection paths revoke before calling here. The social callbacks take
  # the same lock before they write a link (SocialAuthentication#commit_social_link!)
  # and fail when the account is gone, so either the other login completes
  # first and the account stays, or the removal goes first and the other
  # login fails and can be retried (creating a fresh account). Nothing waits
  # on a doomed account, and nothing signs in to one.
  #
  # An account kept that way is kept FOR the adopters it found: the session
  # and refresh token ids that were active, remembered in
  # StandardId.cache_store. When such an adopter's own request then fails
  # too, it revokes what it issued and calls reclaim_for_failed_adopter!,
  # which removes the account after all unless it is still adopted (by
  # someone else, who is then remembered in turn). Only a failing request
  # that issued one of the remembered credentials can trigger the removal,
  # so an adopter that went on to succeed is never undone by a later,
  # unrelated failure. With a cache store that does not share entries
  # across processes (or the null store) nothing is remembered and the kept
  # account stays, as before.
  module AccountCleanup
    module_function

    # How long a kept account remembers its adopters: comfortably longer than
    # the adopting request can take to finish.
    KEPT_FOR_ADOPTERS_TTL = 1.hour

    # @return [Boolean] true when the account was removed, false when it was
    #   already gone or another login has adopted it.
    def destroy_newly_created!(account)
      return false unless account&.persisted?

      ActiveRecord::Base.transaction do
        next false if account.class.lock.where(id: account.id).pick(:id).nil?

        if adopted?(account)
          remember_adopters!(account)
          Rails.logger&.info("[StandardId] Kept refused new account #{account.id}: a concurrent sign-in is using it")
          next false
        end

        remove!(account)
      end
    end

    # Called by a sign-in that matched an EXISTING account and then failed,
    # with the sessions / refresh tokens it issued (already revoked). When a
    # refused request kept that account only because of this sign-in (see
    # destroy_newly_created!), the account is removed after all, unless
    # something else has adopted it since. Anything else is left alone.
    #
    # @return [Boolean] true when the account was removed.
    def reclaim_for_failed_adopter!(account, sessions: [], refresh_tokens: [])
      return false unless account&.persisted?

      issued = credential_keys(Array(sessions).compact.map(&:id), Array(refresh_tokens).compact.map(&:id))
      return false if issued.empty?

      ActiveRecord::Base.transaction do
        next false if account.class.lock.where(id: account.id).pick(:id).nil?

        kept_for = Array(read_kept_for(account))
        next false if (kept_for & issued).empty?

        if adopted?(account)
          remember_adopters!(account)
          next false
        end

        Rails.logger&.info("[StandardId] Removing refused new account #{account.id}: the sign-in it was kept for failed")
        remove!(account)
      end
    end

    # Another request signed in to the account. The refusing request has
    # already revoked whatever session / refresh token it issued itself.
    def adopted?(account)
      return true if account.sessions.strict_loading(false).active.exists?

      StandardId::RefreshToken.active.where(account_id: account.id).exists?
    end

    def remove!(account)
      # Tokens first: refresh_tokens.account_id has no ON DELETE action, and
      # a refused API grant may already have issued one for this account.
      StandardId::RefreshToken.where(account_id: account.id).delete_all
      account.sessions.strict_loading(false).destroy_all
      identifiers = account.identifiers.strict_loading(false).to_a
      identifiers.each { |i| i.credentials.strict_loading(false).destroy_all }
      # Deliberately destroy! (unlike the destroy_all calls above): a failed identifier destroy raises and rolls back the whole cleanup, failing loud instead of leaving a half-cleaned orphan.
      identifiers.each(&:destroy!)
      account.destroy
      forget_kept_for(account)
      true
    end

    # Remembers the adopters the account is being kept for. Best effort: the
    # cache is not part of the transaction, and a cache failure only means
    # the kept account is not reclaimed later.
    def remember_adopters!(account)
      session_ids = account.sessions.strict_loading(false).active.pluck(:id)
      token_ids = StandardId::RefreshToken.active.where(account_id: account.id).pluck(:id)
      StandardId.cache_store&.write(kept_for_key(account), credential_keys(session_ids, token_ids), expires_in: KEPT_FOR_ADOPTERS_TTL)
    rescue StandardError => e
      Rails.logger&.warn("[StandardId] Could not remember the adopters of kept account #{account.id}: #{e.class}: #{e.message}")
    end

    def read_kept_for(account)
      StandardId.cache_store&.read(kept_for_key(account))
    rescue StandardError => e
      Rails.logger&.warn("[StandardId] Could not read the adopters of kept account #{account.id}: #{e.class}: #{e.message}")
      nil
    end

    def forget_kept_for(account)
      StandardId.cache_store&.delete(kept_for_key(account))
    rescue StandardError
      nil
    end

    def kept_for_key(account)
      "standard_id:account_cleanup:kept_for:#{account.class.name}:#{account.id}"
    end

    def credential_keys(session_ids, refresh_token_ids)
      session_ids.map { |id| "session:#{id}" } + refresh_token_ids.map { |id| "refresh_token:#{id}" }
    end

    private_class_method :remove!, :remember_adopters!, :read_kept_for, :forget_kept_for, :kept_for_key, :credential_keys
  end
end
