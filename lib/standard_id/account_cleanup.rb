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
  module AccountCleanup
    module_function

    # @return [Boolean] true when the account was removed, false when it was
    #   already gone or another login has adopted it.
    def destroy_newly_created!(account)
      return false unless account&.persisted?

      ActiveRecord::Base.transaction do
        next false if account.class.lock.where(id: account.id).pick(:id).nil?

        if adopted?(account)
          Rails.logger&.info("[StandardId] Kept refused new account #{account.id}: a concurrent sign-in is using it")
          next false
        end

        # Tokens first: refresh_tokens.account_id has no ON DELETE action, and
        # a refused API grant may already have issued one for this account.
        StandardId::RefreshToken.where(account_id: account.id).delete_all
        account.sessions.strict_loading(false).destroy_all
        identifiers = account.identifiers.strict_loading(false).to_a
        identifiers.each { |i| i.credentials.strict_loading(false).destroy_all }
        # Deliberately destroy! (unlike the destroy_all calls above): a failed identifier destroy raises and rolls back the whole cleanup, failing loud instead of leaving a half-cleaned orphan.
        identifiers.each(&:destroy!)
        account.destroy
        true
      end
    end

    # Another request signed in to the account. The refusing request has
    # already revoked whatever session / refresh token it issued itself.
    def adopted?(account)
      return true if account.sessions.strict_loading(false).active.exists?

      StandardId::RefreshToken.active.where(account_id: account.id).exists?
    end
  end
end
