module StandardId
  # Ends everything an account is signed in with: every session (cascading to
  # the refresh tokens under it), then every refresh token with no session, such
  # as one minted by a grant flow. Sessions alone would leave those alive.
  # Revoking rather than destroying keeps the audit trail and fires one
  # SESSION_REVOKED per session.
  #
  # Runs in one transaction, so a caller that wraps it in its own (a password
  # change, say) commits the change and the revocation together. The
  # SESSION_REVOKED events then publish before that commit; each is rescued
  # (see Session.publish_session_revocations), so a subscriber cannot roll the
  # change back, but one that reads the rows must do so after commit.
  #
  # Access tokens already issued are stateless JWTs and stay valid until they
  # expire.
  module AccessRevocation
    module_function

    # @param account [ActiveRecord::Base]
    # @param reason [String] carried on each SESSION_REVOKED event
    # @param issued_before [Time, nil] only revoke sessions and refresh tokens
    #   CREATED before this. Activity (updated_at) never spares one.
    def revoke_all!(account, reason:, issued_before: nil)
      ActiveRecord::Base.transaction do
        if issued_before
          sessions = StandardId::Session
            .where(account_id: account.id, revoked_at: nil)
            .where(created_at: ...issued_before)
          StandardId::Session.revoke_sessions!(sessions, account: account, reason: reason)
        else
          StandardId::Session.revoke_all_for!(account, reason: reason)
        end

        refresh_tokens = StandardId::RefreshToken.where(account_id: account.id, revoked_at: nil)
        refresh_tokens = refresh_tokens.where(created_at: ...issued_before) if issued_before
        refresh_tokens.update_all(revoked_at: Time.current)
      end
    end
  end
end
