require "rails_helper"

RSpec.describe StandardId::Web::SessionManager do
  let(:session) { {} }
  let(:encrypted_cookies) { {} }
  let(:plain_cookies) { {} }
  let(:encrypted_cookies_mock) do
    double("EncryptedCookies").tap do |ec|
      allow(ec).to receive(:[]) { |key| encrypted_cookies[key] }
      allow(ec).to receive(:[]=) { |key, value| encrypted_cookies[key] = value }
      allow(ec).to receive(:delete) { |key| encrypted_cookies.delete(key) }
    end
  end
  let(:cookies) do
    double("Cookies").tap do |c|
      allow(c).to receive(:encrypted).and_return(encrypted_cookies_mock)
      allow(c).to receive(:[]) { |key| plain_cookies[key] }
      allow(c).to receive(:[]=) { |key, value| plain_cookies[key] = value }
      # A cookie deletion removes the underlying cookie regardless of which jar
      # (plain or encrypted) wrote it — model that so clear_session!'s
      # `cookies.delete(:session_token)` clears the encrypted view too.
      allow(c).to receive(:delete) { |key| plain_cookies.delete(key); encrypted_cookies.delete(key) }
    end
  end
  let(:request) { double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: false) }
  let(:token_manager) { double("TokenManager") }
  let(:reset_session_callable) { nil }
  let(:session_manager) do
    described_class.new(token_manager, request: request, session: session, cookies: cookies, reset_session: reset_session_callable)
  end
  let(:browser_session) { double("BrowserSession", expired?: false, revoked?: false, account: account, expires_at: 1.week.from_now) }
  let(:account) { double("Account") }

  before do
    Current.reset
    allow(Current).to receive(:session).and_return(nil)
    allow(Current).to receive(:session=)
  end

  describe "#current_session" do
    # delivery-ops#598 — the anonymous path. A visitor with no cookies at all
    # must cost zero session-table queries per call, must not allocate (and so
    # persist) a Rails session, and must answer from memo on the second call.
    context "when the request is anonymous (no cookies, Rails session not loaded)" do
      let(:session) do
        double("RackSession", loaded?: false).tap do |s|
          allow(s).to receive(:[]) { raise "session[] must not be read on an anonymous request" }
          allow(s).to receive(:delete) { raise "session.delete must not be called on an anonymous request" }
        end
      end
      let(:request) do
        double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: false,
                          session_options: { key: "_app_session" }, cookies: {})
      end

      before do
        Current.reset
        allow(Current).to receive(:session).and_call_original
        allow(Current).to receive(:session=).and_call_original
      end

      it "returns nil without querying the session table" do
        expect(StandardId::BrowserSession).not_to receive(:eager_load)
        expect(StandardId::PasswordCredential).not_to receive(:find_by_token_for)

        expect(session_manager.current_session).to be_nil
      end

      it "memoises the nil answer for the rest of the request" do
        expect(StandardId::BrowserSession).not_to receive(:eager_load)

        3.times { expect(session_manager.current_session).to be_nil }
        expect(Current.session_resolved).to be(true)
      end

      it "also memoises a nil account" do
        expect(StandardId::BrowserSession).not_to receive(:eager_load)

        3.times { expect(session_manager.current_account).to be_nil }
        expect(Current.account_resolved).to be(true)
      end

      it "does not delete the (absent) cookies either" do
        expect(cookies).not_to receive(:delete)
        session_manager.current_session
      end
    end

    context "when only the legacy session[:session_token] is present (Rails session cookie on the request)" do
      let(:eager_load_relation) { double("EagerLoadRelation") }
      let(:by_token_relation) { double("ByTokenRelation") }
      let(:request) do
        double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: false,
                          session_options: { key: "_app_session" }, cookies: { "_app_session" => "abc" })
      end

      before do
        Current.reset
        allow(Current).to receive(:session).and_call_original
        allow(Current).to receive(:session=).and_call_original
        session[:session_token] = "legacy_token"
        allow(StandardId::BrowserSession).to receive(:eager_load).with(:account).and_return(eager_load_relation)
        allow(eager_load_relation).to receive(:by_token).with("legacy_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(browser_session)
      end

      it "still resolves the session from the Rails session" do
        expect(session_manager.current_session).to eq(browser_session)
      end
    end

    context "when a stale session_token cookie names no session" do
      let(:eager_load_relation) { double("EagerLoadRelation") }
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        Current.reset
        allow(Current).to receive(:session).and_call_original
        allow(Current).to receive(:session=).and_call_original
        encrypted_cookies[:session_token] = "gone_token"
        plain_cookies[:session_token] = "gone_token"
        allow(StandardId::BrowserSession).to receive(:eager_load).with(:account).and_return(eager_load_relation)
        allow(eager_load_relation).to receive(:by_token).with("gone_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(nil)
      end

      it "clears the stale cookie and memoises nil" do
        expect(session_manager.current_session).to be_nil
        expect(plain_cookies[:session_token]).to be_nil
        expect(session_manager.current_session).to be_nil
        expect(Current.session_resolved).to be(true)
      end
    end

    context "when Current.session is present" do
      before do
        allow(Current).to receive(:session).and_return(browser_session)
      end

      it "returns Current.session without loading" do
        result = session_manager.current_session
        expect(result).to eq(browser_session)
      end
    end

    context "when session token exists" do
      let(:eager_load_relation) { double("EagerLoadRelation") }
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        encrypted_cookies[:session_token] = "valid_token"
        allow(StandardId::BrowserSession).to receive(:eager_load).with(:account).and_return(eager_load_relation)
        allow(eager_load_relation).to receive(:by_token).with("valid_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(browser_session)
        # Mock Current.session= to actually store the value for subsequent calls
        allow(Current).to receive(:session=) do |value|
          allow(Current).to receive(:session).and_return(value)
        end
      end

      it "loads session from session token" do
        result = session_manager.current_session
        expect(result).to eq(browser_session)
      end

      it "sets Current.session" do
        expect(Current).to receive(:session=).with(browser_session)
        session_manager.current_session
      end
    end

    context "when remember token exists" do
      let(:password_credential) { double("PasswordCredential", account: account) }

      before do
        plain_cookies[:remember_token] = "remember_token"
        allow(StandardId::PasswordCredential).to receive(:find_by_token_for)
          .with(:remember_me, "remember_token").and_return(password_credential)
        allow(token_manager).to receive(:create_browser_session).with(account, remember_me: true).and_return(browser_session)
        allow(browser_session).to receive(:token).and_return("token_value")
        allow(token_manager).to receive(:create_remember_token).with(password_credential).and_return({ value: "new_remember_token" })
        # Mock Current.session= to actually store the value for subsequent calls
        allow(Current).to receive(:session=) do |value|
          allow(Current).to receive(:session).and_return(value)
        end
      end

      it "creates new browser session from remember token" do
        result = session_manager.current_session
        expect(result).to eq(browser_session)
        expect(token_manager).to have_received(:create_browser_session).with(account, remember_me: true)
      end

      it "sets session token in encrypted cookie" do
        session_manager.current_session
        expect(encrypted_cookies[:session_token]).to include(value: "token_value")
      end

      it "creates new remember token" do
        session_manager.current_session
        expect(plain_cookies[:remember_token]).to eq({ value: "new_remember_token" })
      end
    end

    context "when session is expired" do
      let(:expired_session) { double("BrowserSession", expired?: true, revoked?: false, account: account, expires_at: 1.day.ago) }
      let(:eager_load_relation) { double("EagerLoadRelation") }
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        encrypted_cookies[:session_token] = "expired_token"
        # Let the assignment stick so the expired/revoked branch actually runs
        # (with a no-op `session=` the "no session" branch ran instead and the
        # cookie was only cleared by accident).
        allow(Current).to receive(:session=) do |value|
          allow(Current).to receive(:session).and_return(value)
        end
        allow(StandardId::BrowserSession).to receive(:eager_load).with(:account).and_return(eager_load_relation)
        allow(eager_load_relation).to receive(:by_token).with("expired_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(expired_session)
      end

      it "clears session and returns nil" do
        result = session_manager.current_session
        expect(result).to be_nil
        expect(encrypted_cookies[:session_token]).to be_nil
      end
    end

    context "when session is revoked" do
      let(:revoked_session) { double("BrowserSession", expired?: false, revoked?: true) }
      let(:eager_load_relation) { double("EagerLoadRelation") }
      let(:by_token_relation) { double("ByTokenRelation") }

      before do
        encrypted_cookies[:session_token] = "revoked_token"
        # Let the assignment stick so the expired/revoked branch actually runs
        # (with a no-op `session=` the "no session" branch ran instead and the
        # cookie was only cleared by accident).
        allow(Current).to receive(:session=) do |value|
          allow(Current).to receive(:session).and_return(value)
        end
        allow(StandardId::BrowserSession).to receive(:eager_load).with(:account).and_return(eager_load_relation)
        allow(eager_load_relation).to receive(:by_token).with("revoked_token").and_return(by_token_relation)
        allow(by_token_relation).to receive(:first).and_return(revoked_session)
      end

      it "clears session and returns nil" do
        result = session_manager.current_session
        expect(result).to be_nil
        expect(encrypted_cookies[:session_token]).to be_nil
      end
    end
  end

  describe "#current_account" do
    before do
      allow(Current).to receive(:account).and_return(nil)
      allow(Current).to receive(:account=) do |value|
        allow(Current).to receive(:account).and_return(value)
      end
    end

    context "when session exists with account" do
      let(:account) { Account.create!(name: "Test User", email: "test@example.com") }
      let(:browser_session) { double("BrowserSession", expired?: false, revoked?: false, account: account, account_id: account.id) }

      before do
        allow(Current).to receive(:session).and_return(browser_session)
        allow(StandardId).to receive(:account_class).and_return(Account)
      end

      it "returns the account with strict loading disabled" do
        result = session_manager.current_account
        expect(result).to eq(account)
        expect(result.strict_loading?).to be(false)
      end
    end

    context "when account_scope is configured" do
      let(:account) { Account.create!(name: "Scoped User", email: "scoped@example.com") }
      let(:browser_session) { double("BrowserSession", expired?: false, revoked?: false, account: account, account_id: account.id) }
      let(:scope_lambda) { ->(scope) { scope.where(name: "Scoped User") } }

      before do
        allow(Current).to receive(:session).and_return(browser_session)
        allow(StandardId).to receive(:account_class).and_return(Account)
        allow(StandardId.config).to receive(:account_scope).and_return(scope_lambda)
      end

      it "applies the configured scope when loading the account" do
        result = session_manager.current_account
        expect(result).to eq(account)
      end

      it "returns nil when the scope excludes the account" do
        allow(StandardId.config).to receive(:account_scope).and_return(->(scope) { scope.where(name: "Other") })
        result = session_manager.current_account
        expect(result).to be_nil
      end
    end

    context "when no session exists" do
      before do
        allow(Current).to receive(:session).and_return(nil)
      end

      it "returns nil" do
        expect(session_manager.current_account).to be_nil
      end
    end
  end

  describe "#sign_in_account" do
      context "after an anonymous read in the same request" do
        let(:session) { {} }
        let(:account) { Account.create!(name: "Signing In", email: "signin@example.com") }
        let(:request) do
          double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: false,
                            session_options: { key: "_app_session" }, cookies: {})
        end
        let(:browser_session) { double("BrowserSession", expired?: false, revoked?: false, account: account, token: "new_token", expires_at: 1.week.from_now) }

        before do
          Current.reset
          allow(Current).to receive(:session).and_call_original
          allow(Current).to receive(:session=).and_call_original
          allow(Current).to receive(:account).and_call_original
          allow(Current).to receive(:account=).and_call_original
          allow(token_manager).to receive(:create_browser_session).with(account).and_return(browser_session)
          allow(StandardId::Events).to receive(:publish)
          allow(StandardId).to receive(:account_class).and_return(Account)
        end

        it "does not return the stale memoised nil after sign_in_account" do
          expect(session_manager.current_account).to be_nil
          expect(session_manager.current_session).to be_nil

          session_manager.sign_in_account(account)

          expect(session_manager.current_session).to eq(browser_session)
          expect(session_manager.current_account).to eq(account)
        end

        it "re-derives the account through account_scope rather than trusting the signed-in record" do
          allow(StandardId.config).to receive(:account_scope).and_return(->(scope) { scope.where(name: "Nobody") })
          allow(browser_session).to receive(:account_id).and_return(account.id)
          expect(session_manager.current_account).to be_nil

          session_manager.sign_in_account(account)

          expect(session_manager.current_session).to eq(browser_session)
          expect(session_manager.current_account).to be_nil
      end
    end

    before do
      allow(browser_session).to receive(:token).and_return("new_token")
      allow(token_manager).to receive(:create_browser_session).with(account).and_return(browser_session)
      allow(StandardId::Events).to receive(:publish)
    end

    context "when reset_session is provided" do
      let(:reset_session_callable) { spy("reset_session") }

      it "calls reset_session before creating the browser session" do
        call_order = []
        allow(reset_session_callable).to receive(:call) { call_order << :reset }
        allow(token_manager).to receive(:create_browser_session) { call_order << :create; browser_session }

        session_manager.sign_in_account(account)

        expect(call_order).to eq(%i[reset create])
      end

      it "stores the session token" do
        session_manager.sign_in_account(account)
        expect(session[:session_token]).to eq("new_token")
        expect(encrypted_cookies[:session_token]).to include(value: "new_token")
      end
    end

    context "when reset_session is nil (backward compat)" do
      let(:reset_session_callable) { nil }

      it "does not raise an error" do
        expect { session_manager.sign_in_account(account) }.not_to raise_error
      end

      it "stores the session token" do
        session_manager.sign_in_account(account)
        expect(session[:session_token]).to eq("new_token")
      end
    end

    context "with scope_name" do
      it "stores the scope name in the session" do
        session_manager.sign_in_account(account, scope_name: "admin")
        expect(session[:standard_id_scopes]).to eq(["admin"])
      end

      it "accumulates scopes across multiple sign-ins without duplicates" do
        session_manager.sign_in_account(account, scope_name: "admin")
        session_manager.sign_in_account(account, scope_name: "member")
        expect(session[:standard_id_scopes]).to eq(["admin", "member"])
      end

      it "does not add duplicate scopes" do
        session_manager.sign_in_account(account, scope_name: "admin")
        session_manager.sign_in_account(account, scope_name: "admin")
        expect(session[:standard_id_scopes]).to eq(["admin"])
      end

      it "converts scope_name to string" do
        session_manager.sign_in_account(account, scope_name: :admin)
        expect(session[:standard_id_scopes]).to eq(["admin"])
      end

      it "does not store scopes when scope_name is nil" do
        session_manager.sign_in_account(account, scope_name: nil)
        expect(session[:standard_id_scopes]).to be_nil
      end
    end

    context "with scope preservation across session fixation reset" do
      let(:reset_session_callable) do
        proc { session.clear }
      end

      it "preserves existing scopes across session reset" do
        session[:standard_id_scopes] = ["admin"]
        session_manager.sign_in_account(account, scope_name: "member")
        expect(session[:standard_id_scopes]).to eq(["admin", "member"])
      end

      # Simulates a user who already has one scope and re-authenticates
      # (e.g. session fixation reset) without adding a new scope.
      it "preserves scopes even when no new scope_name is provided" do
        session[:standard_id_scopes] = ["admin"]
        session_manager.sign_in_account(account)
        expect(session[:standard_id_scopes]).to eq(["admin"])
      end
    end

    context "persistent session cookie" do
      it "writes the cookie with an expiry tied to the session's expires_at" do
        session_manager.sign_in_account(account)
        cookie = encrypted_cookies[:session_token]
        expect(cookie[:expires]).to eq(browser_session.expires_at)
        expect(cookie[:expires]).to be > Time.current
      end

      it "hardens the cookie (httponly, same_site) and follows request.ssl? for secure" do
        session_manager.sign_in_account(account)
        cookie = encrypted_cookies[:session_token]
        expect(cookie).to include(httponly: true, same_site: :lax, secure: false)
      end

      context "on an SSL request" do
        let(:request) { double("Request", remote_ip: "127.0.0.1", user_agent: "Test Browser", ssl?: true) }

        it "sets secure: true on the cookie" do
          session_manager.sign_in_account(account)
          expect(encrypted_cookies[:session_token]).to include(secure: true)
        end
      end
    end
  end

  describe "#current_scope_names" do
    it "returns an empty array when no scopes are set" do
      expect(session_manager.current_scope_names).to eq([])
    end

    it "returns the stored scope names" do
      session[:standard_id_scopes] = ["admin", "member"]
      expect(session_manager.current_scope_names).to eq(["admin", "member"])
    end
  end

  describe "#load_session_from_remember_token (session fixation)" do
    let(:password_credential) { double("PasswordCredential", account: account) }
    let(:reset_session_callable) { spy("reset_session") }

    before do
      plain_cookies[:remember_token] = "remember_token"
      allow(StandardId::PasswordCredential).to receive(:find_by_token_for)
        .with(:remember_me, "remember_token").and_return(password_credential)
      allow(token_manager).to receive(:create_browser_session).with(account, remember_me: true).and_return(browser_session)
      allow(browser_session).to receive(:token).and_return("token_value")
      allow(token_manager).to receive(:create_remember_token).with(password_credential).and_return({ value: "new_remember_token" })
      allow(Current).to receive(:session=) do |value|
        allow(Current).to receive(:session).and_return(value)
      end
    end

    it "calls reset_session before creating the browser session" do
      call_order = []
      allow(reset_session_callable).to receive(:call) { call_order << :reset }
      allow(token_manager).to receive(:create_browser_session) { |*_args, **_kwargs| call_order << :create; browser_session }

      session_manager.current_session
      expect(call_order).to eq(%i[reset create])
    end
  end

  describe "#clear_session!" do
    before do
      encrypted_cookies[:session_token] = "token"
      plain_cookies[:remember_token] = "remember"
      allow(Current).to receive(:session=)
    end

    # clear_session! now uses cookies.delete(:session_token) rather than
    # cookies.encrypted[:session_token] = nil — the latter wrote a fresh
    # non-HttpOnly encrypted blob on every unauthenticated request.
    it "deletes session token cookie" do
      session_manager.clear_session!
      expect(encrypted_cookies[:session_token]).to be_nil
    end

    it "deletes remember token cookie" do
      session_manager.clear_session!
      expect(plain_cookies[:remember_token]).to be_nil
    end

    it "clears Current.session" do
      expect(Current).to receive(:session=).with(nil)
      session_manager.clear_session!
    end

    it "clears standard_id_scopes from session" do
      session[:standard_id_scopes] = %w[borrower lender]
      session_manager.clear_session!
      expect(session[:standard_id_scopes]).to be_nil
    end
  end
end
