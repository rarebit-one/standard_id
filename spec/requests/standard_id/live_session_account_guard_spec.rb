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

    # 0.36.0 made these two raiseable on a live request for the first time, but
    # Api::BaseController rescued neither, so the very fix that started refusing
    # a disabled account's token turned every gem-owned API route into a 500 for
    # it. A 500 is not a refusal: it carries no WWW-Authenticate, tells the
    # client nothing about discarding the token, and pages the on-call. Both
    # must land as the same clean 401 the other credential failures produce.
    #
    # NEGATIVE CONTROL for this pair specifically: delete the two account
    # `rescue_from` lines from StandardId::Api::BaseController and both examples
    # must fail with the raw error escaping the request.
    it "401s an already-issued access token once the account is deactivated" do
      account.deactivate!

      http_get "/api/sessions", headers: headers

      expect(response).to have_http_status(:unauthorized)
      expect(json_body["error"]).to eq("invalid_token")
      expect(json_body["error_description"]).to eq("The account is deactivated")
      expect(response.headers["WWW-Authenticate"]).to include(%(error="invalid_token"))
    end

    it "401s an already-issued access token once the account is locked" do
      account.lock!(reason: "Suspicious activity")

      http_get "/api/sessions", headers: headers

      expect(response).to have_http_status(:unauthorized)
      expect(json_body["error"]).to eq("invalid_token")
      expect(json_body["error_description"]).to eq("The account is locked")
    end

    # lock_reason is operator-authored text for logs and admin screens. It must
    # not reach the client, in either the body or the WWW-Authenticate header.
    it "does not leak lock_reason to the client" do
      account.lock!(reason: "Suspicious activity")

      http_get "/api/sessions", headers: headers

      expect(response.body).not_to include("Suspicious activity")
      expect(response.headers["WWW-Authenticate"]).not_to include("Suspicious activity")
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

    # The web engine's OWN routes (/sessions, /account, /logout) are the
    # counterpart of the API 500 fixed above — and they are deliberately NOT
    # fixed the same way.
    #
    # StandardId::Web::BaseController descends from the HOST's
    # ApplicationController, so a host `rescue_from StandardId::AccountDeactivatedError`
    # — exactly what the README tells hosts to write — already covers these
    # routes. The gem adding its own `rescue_from` on Web::BaseController would
    # not add safety, it would REMOVE it: Rails resolves rescue_from handlers
    # most-recently-registered-first, and a subclass registers after its parent,
    # so a gem handler on Web::BaseController would outrank and silently
    # override the host's. Api::BaseController has no such escape hatch — it
    # descends from ActionController::API, which is why only that side is
    # rescued in the gem.
    #
    # These examples pin both halves of that claim. The dummy app installs no
    # account handler, so the first documents the raw propagation a host sees if
    # it ignores the README; the second pins the structural property that makes
    # a host handler work at all, and is the one that would fail if someone
    # "fixed" the web side the way the API side was fixed.
    describe "gem-owned web routes (/sessions)" do
      it "propagates to the host when the host installed no handler" do
        sign_in_as(account)
        Account.where(id: account.id).update_all(status: "inactive")

        expect {
          http_get "/sessions"
        }.to raise_error(StandardId::AccountDeactivatedError, "Account is deactivated")
      end

      it "leaves the account errors for the host's ApplicationController to rescue" do
        expect(StandardId::Web::BaseController.ancestors).to include(ApplicationController)

        # `rescue_handlers` is a class_attribute, so this array is Web::BaseController's
        # own copy: the host's registrations (snapshotted from ApplicationController
        # when this class was defined) first, the gem's appended after. Rails scans it
        # in reverse, so anything the gem registers here outranks the host. The gem
        # therefore registers NOTHING for the account errors on the web side.
        gem_registered = StandardId::Web::BaseController.rescue_handlers.map(&:first)
        expect(gem_registered).to include("StandardId::InvalidSessionError")
        expect(gem_registered).not_to include("StandardId::AccountDeactivatedError")
        expect(gem_registered).not_to include("StandardId::AccountLockedError")
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
