# Helper for proving AccountStatus / AccountLocking enforcement through the
# REAL publisher rather than a hand-built event payload.
#
# The concern specs used to assert enforcement with
# `Events.publish(SESSION_VALIDATING, account: account)` — supplying the very
# key the real publisher omitted. The subscriber reacted, the spec passed, and
# the guard was inert in every consumer app for months (rarebit-ops#306).
#
# This drives StandardId::Web::AuthenticationGuard#require_session! over a real
# BrowserSession row, so the payload is built by production code. The session
# manager is stubbed only to hand the guard a session — the payload shaping,
# which is what regressed, is entirely real.
module LiveSessionHelpers
  # Validate a live (active, unexpired, unrevoked) browser session for the
  # given account through the real web authentication guard.
  #
  # @param account [Object] the account to open a session for
  # @return [StandardId::BrowserSession] the validated session
  def validate_live_browser_session(account)
    browser_session = StandardId::BrowserSession.create!(
      account: account,
      ip_address: "127.0.0.1",
      user_agent: "RSpec",
      expires_at: StandardId::BrowserSession.expiry
    )

    session_manager = double("SessionManager", current_session: browser_session)
    request = double("Request", url: "http://example.com/protected")

    StandardId::Web::AuthenticationGuard.new.require_session!(
      session_manager,
      session: {},
      request: request
    )
  end
end

RSpec.configure do |config|
  config.include LiveSessionHelpers
end
