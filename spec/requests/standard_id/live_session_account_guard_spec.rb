require "rails_helper"

# End-to-end proof that AccountStatus / AccountLocking stop a LIVE, already
# authenticated request — not merely a sign-in or a token mint.
#
# Why this file exists (rarebit-ops#306). The concern specs proved enforcement
# by publishing SESSION_VALIDATING BY HAND with an `account:` key. That proves
# the subscriber reacts to a correctly-shaped payload; it cannot prove any
# caller produces that shape — and neither caller did. Both AuthenticationGuards
# published `session:` alone, so `event[:account]` was nil and the
# SESSION_VALIDATING leg of both guards never fired in any consumer app.
#
# What that cost, precisely — the gap is narrower than "no enforcement" but
# real, and these three scenarios are exactly the ones the revocation
# subscribers cannot cover:
#
#   1. API bearer tokens. AccountStatusSubscriber / AccountLockingSubscriber
#      revoke `account.sessions.active` on deactivate!/lock!, but an access
#      token is a stateless JWT with no Session row — revoking sessions does
#      nothing to it. Until it expires, SESSION_VALIDATING was the only thing
#      that could have stopped it, and it was inert.
#   2. A status change that does not run the after_commit — update_all,
#      update_column, a data migration, direct SQL, an admin bulk action. No
#      ACCOUNT_DEACTIVATED / ACCOUNT_LOCKED event, so no session revocation.
#   3. A session minted AFTER the account went bad by a path that does not
#      emit SESSION_CREATING. Web::SessionManager#load_session_from_remember_token
#      calls token_manager.create_browser_session directly and emits nothing,
#      so remember-me re-auth walks straight past the sign-in guard.
#
# Nothing below constructs an event payload: every example drives a real HTTP
# request through the real AuthenticationGuard.
#
# NEGATIVE CONTROL: delete the `account:` key from `emit_session_validating` in
# lib/standard_id/{web,api}/authentication_guard.rb and every rejection example
# here must fail. A guard spec nobody has watched fail is not evidence.
RSpec.describe "Live-session account enforcement", type: :request do
  let(:account) do
    Account.create!(name: "Live Session", email: "live-#{SecureRandom.hex(4)}@example.com")
  end

  describe "api (StandardId::Api::AuthenticationGuard)" do
    # Issued while the account is healthy, and never revocable: the session
    # revocation subscribers have nothing to revoke for a stateless JWT.
    let!(:token) { bearer_jwt(account: account, scope: "openid") }
    let(:headers) { auth_headers(token) }

    it "allows the request while the account is active and unlocked" do
      http_get "/api/sessions", headers: headers

      expect(response).to have_http_status(:ok)
    end

    it "rejects an already-issued access token once the account is deactivated" do
      account.deactivate!

      expect {
        http_get "/api/sessions", headers: headers
      }.to raise_error(StandardId::AccountDeactivatedError, "Account is deactivated")
    end

    it "rejects an already-issued access token once the account is locked" do
      account.lock!(reason: "Suspicious activity")

      expect {
        http_get "/api/sessions", headers: headers
      }.to raise_error(StandardId::AccountLockedError) do |error|
        expect(error.lock_reason).to eq("Suspicious activity")
      end
    end

    it "still 401s a request with no token" do
      http_get "/api/sessions"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "web (StandardId::Web::AuthenticationGuard)" do
    it "allows the request while the account is active and unlocked" do
      sign_in_as(account)

      http_get admin_root_path

      expect(response).to have_http_status(:ok)
    end

    context "when the status change skipped the callbacks (no session revocation)" do
      before { sign_in_as(account) }

      it "rejects the live session of a deactivated account" do
        Account.where(id: account.id).update_all(status: "inactive")
        expect(StandardId::BrowserSession.where(account_id: account.id).first.revoked_at).to be_nil

        expect {
          http_get admin_root_path
        }.to raise_error(StandardId::AccountDeactivatedError, "Account is deactivated")
      end

      it "rejects the live session of a locked account" do
        Account.where(id: account.id).update_all(locked: true, lock_reason: "Suspicious activity")
        expect(StandardId::BrowserSession.where(account_id: account.id).first.revoked_at).to be_nil

        expect {
          http_get admin_root_path
        }.to raise_error(StandardId::AccountLockedError)
      end
    end

    context "when the session was minted after the account went bad" do
      # Mirrors the remember-me re-auth hole: create_browser_session emits no
      # SESSION_CREATING, so the sign-in guard never sees this session.
      it "rejects a session minted for a deactivated account" do
        account.deactivate!
        sign_in_as(account)

        expect {
          http_get admin_root_path
        }.to raise_error(StandardId::AccountDeactivatedError, "Account is deactivated")
      end

      it "rejects a session minted for a locked account" do
        account.lock!(reason: "Suspicious activity")
        sign_in_as(account)

        expect {
          http_get admin_root_path
        }.to raise_error(StandardId::AccountLockedError)
      end
    end

    it "still redirects an unauthenticated request to login" do
      http_get admin_root_path

      expect(response).to have_http_status(:found)
      expect(response.location).to include("/login")
    end
  end

  # SESSION_VALIDATING is emitted BEFORE the blank/expired/revoked checks, so
  # resolving an account there must not disturb any of those outcomes and must
  # not blow up on a nil session — see Web::AuthenticationGuard#resolve_account.
  describe "guard-ordering safety" do
    it "reports a revoked session as revoked, not as a missing account" do
      browser_session = sign_in_as(account)
      browser_session.revoke!

      http_get admin_root_path

      expect(response).to have_http_status(:found)
      expect(response.location).to include("/login")
    end
  end
end
