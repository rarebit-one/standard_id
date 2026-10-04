require "rails_helper"

# config.login_method_policy must be consulted on EVERY path that establishes
# a new authentication, before any session or token exists.
#
# This file is the inventory. Each row is one session-creating path, run three
# ways: with no policy (0.44 behaviour), with an allowing policy (the policy
# sees the right context, exactly once) and with a refusing policy (nothing is
# created, the flow answers with its usual denial shape, the refusal is
# audited). The "inventory is complete" block below fails when a flow, a token
# grant or a session-creating call site appears that this table does not know
# about — add a row (or classify the grant) rather than loosening the check.
RSpec.describe "config.login_method_policy on every session-creating path", type: :request do
  let(:email) { "policy-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "s3cureP@ss" }
  let(:deny_message) { "Staff must sign in with the org IdP" }
  let(:token_path) { "/api/oauth/token" }

  def existing_account
    @existing_account ||= Account.create!(name: "Existing", email: email).tap do |account|
      StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current, provider: "google")
    end
  end

  def stub_google(info)
    allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
    allow(StandardId.config).to receive(:google_client_secret).and_return("google-secret")
    allow(StandardId::Providers::Google).to receive(:get_user_info).and_return(
      { user_info: info, tokens: { access_token: "provider-token" } }.with_indifferent_access
    )
  end

  def json
    JSON.parse(response.body)
  end

  def expect_web_refusal
    expect(response).to redirect_to("/login")
    expect(flash[:alert]).to eq(deny_message)
  end

  def expect_api_refusal
    expect(response).to have_http_status(:forbidden)
    expect(json).to eq("error" => "access_denied", "error_description" => deny_message)
  end

  def expect_web_sign_in
    expect(response).to have_http_status(:redirect)
    expect(response.location).not_to end_with("/login")
  end

  def expect_token_response
    expect(response).to have_http_status(:ok)
    expect(json["access_token"]).to be_present
  end

  def web_session_manager
    request_double = double("Request", remote_ip: "127.0.0.1", user_agent: "RSpec", ssl?: false)
    jar = ActionDispatch::Request.new(Rails.application.env_config.dup).cookie_jar
    StandardId::Web::SessionManager.new(StandardId::Web::TokenManager.new(request_double), request: request_double, session: {}, cookies: jar)
  end

  def api_token_manager
    StandardId::Api::TokenManager.new(
      instance_double(ActionDispatch::Request, headers: {}, remote_ip: "127.0.0.1", user_agent: "RSpec", ssl?: false)
    )
  end

  # Runs a host-code primitive, keeping the outcome for the assertions.
  def capture_outcome
    @outcome = yield
  rescue StandardId::LoginMethodDenied => e
    @outcome = e
  end

  PATHS = [
    {
      flow: :web_password, auth_method: :password, provider: nil,
      setup: -> { create_account_with_password(email: email, password: password) },
      perform: -> { http_post "/login", params: { login: { email: email, password: password } } },
      allowed: -> { expect_web_sign_in },
      refused: -> { expect_web_refusal }
    },
    {
      flow: :web_signup, auth_method: :password, provider: nil,
      setup: -> { },
      perform: -> { http_post "/signup", params: { signup: { email: email, password: password, password_confirmation: password } } },
      allowed: -> { expect_web_sign_in },
      refused: -> {
        expect_web_refusal
        expect(Account.find_by(email: email)).to be_nil # the just-created account is removed again
      }
    },
    {
      flow: :web_passwordless, auth_method: :passwordless, provider: nil,
      setup: -> {
        existing_account
        allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
        allow(StandardId.config.passwordless).to receive(:connection).and_return("email")
        http_post "/login", params: { login: { email: email } }
        expect(response).to have_http_status(:see_other)
      },
      perform: -> { http_patch "/login_verify", params: { code: StandardId::CodeChallenge.last.code.to_s } },
      allowed: -> { expect_web_sign_in },
      refused: -> { expect_web_refusal }
    },
    {
      flow: :web_social, auth_method: :social, provider: "google",
      setup: -> {
        existing_account
        stub_google("email" => email, "email_verified" => true, "sub" => "google-sub-1")
        allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
          .to receive(:consume_oauth_request).and_return({ "params" => { "redirect_uri" => "/dashboard" }, "nonce" => nil })
      },
      perform: -> { http_get "/auth/callback/google", params: { state: "state-1", code: "code-1" } },
      allowed: -> { expect(response).to redirect_to("/dashboard") },
      refused: -> { expect_web_refusal }
    },
    {
      flow: :web_remember_me, auth_method: :remember_me, provider: nil,
      setup: -> {
        create_account_with_password(email: email, password: password)
        cookies[:remember_token] = StandardId::PasswordCredential.find_by(login: email).generate_token_for(:remember_me)
      },
      perform: -> { http_get "/login" },
      # Not exercised with an allowing policy here: see the note in the
      # "allowed" example below.
      allowed: nil,
      refused: -> {
        expect(response).to have_http_status(:ok) # rendered the login page: signed out, not an error
        expect(cookies[:remember_token]).to be_blank
      }
    },
    {
      flow: :web_session, auth_method: :unspecified, provider: nil,
      setup: -> { existing_account },
      perform: -> { capture_outcome { web_session_manager.sign_in_account(existing_account) } },
      allowed: -> { expect(@outcome).to be_a(StandardId::BrowserSession) },
      refused: -> { expect(@outcome).to be_a(StandardId::LoginMethodDenied).and(have_attributes(message: deny_message)) }
    },
    {
      flow: :oauth_password_grant, auth_method: :password, provider: nil,
      setup: -> { create_account_with_password(email: email, password: password) },
      perform: -> { post token_path, params: { grant_type: "password", username: email, password: password, client_id: "test-client" }, as: :json },
      allowed: -> { expect_token_response },
      refused: -> { expect_api_refusal }
    },
    {
      flow: :oauth_passwordless_otp_grant, auth_method: :passwordless, provider: nil,
      setup: -> {
        existing_account
        StandardId::CodeChallenge.create!(
          realm: "authentication", channel: "email", target: email, code: "123456",
          expires_at: 10.minutes.from_now, ip_address: "127.0.0.1", user_agent: "RSpec"
        )
      },
      perform: -> {
        post token_path, params: { grant_type: "passwordless_otp", username: email, otp: "123456", connection: "email", client_id: "test-client" }, as: :json
      },
      allowed: -> { expect_token_response },
      refused: -> { expect_api_refusal }
    },
    {
      flow: :oauth_social_callback, auth_method: :social, provider: "google",
      setup: -> {
        existing_account
        stub_google("email" => email, "email_verified" => true, "sub" => "google-sub-2")
      },
      perform: -> { post "/api/oauth/callback/google", params: { code: "code-2" } },
      allowed: -> { expect_token_response },
      refused: -> { expect_api_refusal }
    },
    {
      # Re-checked with the ORIGINAL sign-in's method (here the password
      # grant's), recorded on the refresh token. Refused as a dead token.
      flow: :oauth_refresh_token, auth_method: :password, provider: nil,
      setup: -> {
        create_account_with_password(email: email, password: password)
        post token_path, params: { grant_type: "password", username: email, password: password, client_id: "test-client" }, as: :json
        @refresh_token = json.fetch("refresh_token")
      },
      perform: -> { post token_path, params: { grant_type: "refresh_token", refresh_token: @refresh_token, client_id: "test-client" }, as: :json },
      allowed: -> { expect_token_response },
      refused: -> {
        expect(response).to have_http_status(:bad_request)
        expect(json).to eq("error" => "invalid_grant", "error_description" => "Refresh token is no longer valid")
        expect(StandardId::RefreshToken.active).to be_empty # the family is revoked
      }
    },
    {
      flow: :api_device_session, auth_method: :unspecified, provider: nil,
      setup: -> { existing_account },
      perform: -> { capture_outcome { api_token_manager.create_device_session(existing_account) } },
      allowed: -> { expect(@outcome).to be_a(StandardId::DeviceSession) },
      refused: -> { expect(@outcome).to be_a(StandardId::LoginMethodDenied) }
    },
    {
      flow: :api_service_session, auth_method: :unspecified, provider: nil,
      setup: -> { existing_account },
      perform: -> {
        capture_outcome do
          api_token_manager.create_service_session(existing_account, service_name: "svc", service_version: "1.0", owner: existing_account)
        end
      },
      allowed: -> { expect(@outcome).to be_a(StandardId::ServiceSession) },
      refused: -> { expect(@outcome).to be_a(StandardId::LoginMethodDenied) }
    }
  ].freeze

  def with_policy(policy)
    allow(StandardId.config).to receive(:login_method_policy).and_return(policy)
  end

  def capture_denied_events(&block)
    events = []
    subscription = StandardId::Events.subscribe(StandardId::Events::AUTHENTICATION_METHOD_DENIED) { |event| events << event }
    block.call
    events
  ensure
    StandardId::Events.unsubscribe(subscription)
  end

  PATHS.each do |path|
    describe "flow #{path[:flow].inspect}" do
      before do
        instance_exec(&path[:setup])
      end

      if path[:allowed]
        it "behaves as before when no policy is configured" do
          events = capture_denied_events { instance_exec(&path[:perform]) }

          instance_exec(&path[:allowed])
          expect(events).to be_empty
        end

        it "consults an allowing policy once, with the flow's context" do
          calls = []
          with_policy(->(account:, auth_method:, provider:, request:, flow:) {
            calls << { account_id: account.id, auth_method:, provider:, flow:, request: request.present? }
            true
          })

          instance_exec(&path[:perform])

          instance_exec(&path[:allowed])
          expect(calls.size).to eq(1)
          expect(calls.first).to include(auth_method: path[:auth_method], provider: path[:provider], flow: path[:flow])
          expect(calls.first[:account_id]).to be_present
        end
      else
        # web_remember_me: remember-me re-auth calls
        # `token_manager.create_browser_session(account, remember_me: true)`,
        # but Web::TokenManager#create_browser_session takes no `remember_me:`, so
        # with the real token manager the allowed path raises ArgumentError
        # (pre-existing; the unit spec stubs the token manager). Tracked
        # separately; the policy is still checked first, which is what the
        # refusal example proves.
        it "is documented as not exercisable when allowed (pre-existing remember-me bug)" do
          parameters = StandardId::Web::TokenManager.instance_method(:create_browser_session).parameters
          expect(parameters.map(&:last)).not_to include(:remember_me)
        end
      end

      it "refuses before any session or token is created, and audits the refusal" do
        with_policy(->(**) { raise StandardId::LoginMethodDenied, deny_message })

        events = nil
        expect {
          events = capture_denied_events { instance_exec(&path[:perform]) }
        }.not_to change { [StandardId::Session.count, StandardId::RefreshToken.count] }

        instance_exec(&path[:refused])
        expect(events.size).to eq(1)
        expect(events.first[:flow]).to eq(path[:flow].to_s)
        expect(events.first[:auth_method]).to eq(path[:auth_method].to_s)
        expect(events.first[:provider]).to eq(path[:provider])
      end
    end
  end

  # Not only the policy: any rejection after the link was written must undo
  # it (and a just-created account). Codex P2 on #363.
  describe "a social login rejected for other reasons leaves nothing behind" do
    let!(:legacy_account) do
      Account.create!(name: "Legacy", email: email).tap do |account|
        StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
      end
    end

    def expect_nothing_left(&block)
      expect(&block).not_to change { [Account.count, StandardId::Identifier.count, StandardId::SocialIdentity.count, StandardId::Session.count] }
      expect(StandardId::EmailIdentifier.find_by(value: email).provider).to be_nil
    end

    it "API callback, invalid scope (SocialFlow.new raises InvalidScopeError)" do
      allow(StandardId.config.social).to receive(:available_scopes).and_return(["openid"])
      stub_google("email" => email, "email_verified" => true, "sub" => "g-bad-scope")

      expect_nothing_left { post "/api/oauth/callback/google", params: { code: "c", scope: "admin" } }
      expect(response).to have_http_status(:bad_request)
      expect(json["error"]).to eq("invalid_scope")
    end

    it "API callback, audience/profile binding mismatch (InvalidGrantError from the grant)" do
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return({ "admin_api" => ["AdminProfile"] })
      allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(->(**) { nil })
      stub_google("email" => email, "email_verified" => true, "sub" => "g-bad-aud")

      expect_nothing_left { post "/api/oauth/callback/google", params: { code: "c", audience: "admin_api" } }
      expect(response).to have_http_status(:bad_request)
      expect(json["error"]).to eq("invalid_grant")
    end

    it "API callback, invalid scope for a NEW account removes the account too" do
      allow(StandardId.config.social).to receive(:available_scopes).and_return(["openid"])
      stub_google("email" => "new-#{email}", "email_verified" => true, "sub" => "g-new-bad-scope")

      expect {
        post "/api/oauth/callback/google", params: { code: "c", scope: "admin" }
      }.not_to change { [Account.count, StandardId::Identifier.count, StandardId::SocialIdentity.count] }
      expect(response).to have_http_status(:bad_request)
    end

    it "web callback, unexpected error after sign-in (no link, no new account, no session)" do
      stub_google("email" => "new-#{email}", "email_verified" => true, "sub" => "g-web-boom")
      allow(StandardId.config).to receive(:after_account_created).and_return(->(_a, _r, _c) { raise "hook bug" })
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
        .to receive(:consume_oauth_request).and_return({ "params" => {}, "nonce" => nil })

      expect {
        expect { http_get "/auth/callback/google", params: { state: "s", code: "c" } }.to raise_error(RuntimeError, "hook bug")
      }.not_to change { [Account.count, StandardId::Identifier.count, StandardId::SocialIdentity.count, StandardId::Session.active.count] }
    end
  end

  # Codex round 2 on #363.
  describe "rejections at the edges of the social callbacks" do
    let!(:existing) do
      Account.create!(name: "Existing", email: email).tap do |account|
        StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
      end
    end

    def raise_on(event_name, message)
      subscription = StandardId::Events.subscribe(event_name) { |_event| raise message }
      yield
    ensure
      StandardId::Events.unsubscribe(subscription)
    end

    it "API: a failing SOCIAL_AUTH_COMPLETED subscriber leaves no link and no usable token" do
      stub_google("email" => email, "email_verified" => true, "sub" => "g-completed-boom")

      raise_on(StandardId::Events::SOCIAL_AUTH_COMPLETED, "subscriber bug") do
        expect { post "/api/oauth/callback/google", params: { code: "c" } }.to raise_error(RuntimeError, "subscriber bug")
      end

      expect(StandardId::SocialIdentity.where(subject: "g-completed-boom")).to be_empty
      expect(StandardId::EmailIdentifier.find_by(value: email).provider).to be_nil
      expect(StandardId::RefreshToken.where(account_id: existing.id).active).to be_empty
    end

    it "API: a failing SOCIAL_AUTH_COMPLETED subscriber for a NEW account removes it and its tokens" do
      stub_google("email" => "new-#{email}", "email_verified" => true, "sub" => "g-completed-new")

      raise_on(StandardId::Events::SOCIAL_AUTH_COMPLETED, "subscriber bug") do
        expect {
          expect { post "/api/oauth/callback/google", params: { code: "c" } }.to raise_error(RuntimeError)
        }.not_to change { [Account.count, StandardId::RefreshToken.count, StandardId::SocialIdentity.count] }
      end
    end

    it "web: a session created before sign_in_account raises is revoked" do
      stub_google("email" => email, "email_verified" => true, "sub" => "g-session-boom")
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
        .to receive(:consume_oauth_request).and_return({ "params" => {}, "nonce" => nil })

      raise_on(StandardId::Events::SESSION_CREATED, "session subscriber bug") do
        expect { http_get "/auth/callback/google", params: { state: "s", code: "c" } }.to raise_error(RuntimeError, "session subscriber bug")
      end

      expect(StandardId::BrowserSession.where(account_id: existing.id)).to exist
      expect(StandardId::BrowserSession.where(account_id: existing.id).active).to be_empty
      expect(StandardId::SocialIdentity.where(subject: "g-session-boom")).to be_empty
    end

    # Request A is rejected while a concurrent request B, for the same
    # (provider, sub), links/adopts the row and succeeds. A must not delete it.
    # Simulated by doing B's write from inside A's policy check — the point at
    # which A is about to be rejected.
    [
      ["web", -> { http_get "/auth/callback/google", params: { state: "s", code: "c" } }],
      ["API", -> { post "/api/oauth/callback/google", params: { code: "c" } }]
    ].each do |label, perform|
      it "#{label}: a rejected login does not undo a concurrent successful link" do
        stub_google("email" => email, "email_verified" => true, "sub" => "g-race")
        allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
          .to receive(:consume_oauth_request).and_return({ "params" => {}, "nonce" => nil })
        visible_to_b = nil
        with_policy(->(account:) {
          visible_to_b = StandardId::SocialIdentity.exists?(provider: "google", subject: "g-race")
          identifier = StandardId::EmailIdentifier.find_by(value: email)
          identifier.update!(provider: "google") # B's backfill
          StandardId::SocialIdentity.find_or_create_by!(provider: "google", subject: "g-race") do |si|
            si.account = account
            si.identifier = identifier
          end
          false
        })

        instance_exec(&perform)

        expect(visible_to_b).to be(false) # A never exposed an uncommitted-to link
        expect(StandardId::SocialIdentity.where(provider: "google", subject: "g-race")).to exist
        expect(StandardId::EmailIdentifier.find_by(value: email).provider).to eq("google")
      end
    end
  end

  describe "a refused social login leaves no provider link behind" do
    before { with_policy(->(**) { false }) }

    # A pre-provider-tracking identifier (provider NULL) on an existing
    # account: a successful login would link the sub AND backfill the provider.
    let!(:legacy_account) do
      Account.create!(name: "Legacy", email: email).tap do |account|
        StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
      end
    end

    it "web callback: no SocialIdentity, provider not backfilled" do
      stub_google("email" => email, "email_verified" => true, "sub" => "g-web-refused")
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
        .to receive(:consume_oauth_request).and_return({ "params" => {}, "nonce" => nil })

      expect { http_get "/auth/callback/google", params: { state: "s", code: "c" } }
        .not_to change(StandardId::SocialIdentity, :count)
      expect(response).to redirect_to("/login")
      expect(StandardId::EmailIdentifier.find_by(value: email).provider).to be_nil
      expect(Account.exists?(legacy_account.id)).to be(true)
    end

    it "web callback: also when before_sign_in refuses" do
      allow(StandardId.config).to receive(:login_method_policy).and_return(nil)
      allow(StandardId.config).to receive(:before_sign_in).and_return(->(_a, _r, _c) { { error: "Nope" } })
      stub_google("email" => email, "email_verified" => true, "sub" => "g-web-hook")
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
        .to receive(:consume_oauth_request).and_return({ "params" => {}, "nonce" => nil })

      expect { http_get "/auth/callback/google", params: { state: "s", code: "c" } }
        .not_to change(StandardId::SocialIdentity, :count)
      expect(StandardId::EmailIdentifier.find_by(value: email).provider).to be_nil
    end

    it "API callback: no SocialIdentity, provider not backfilled" do
      stub_google("email" => email, "email_verified" => true, "sub" => "g-api-refused")

      expect { post "/api/oauth/callback/google", params: { code: "c" } }
        .not_to change(StandardId::SocialIdentity, :count)
      expect(response).to have_http_status(:forbidden)
      expect(StandardId::EmailIdentifier.find_by(value: email).provider).to be_nil
      expect(Account.exists?(legacy_account.id)).to be(true)
    end

    it "keeps a link that existed before the refused login" do
      identifier = StandardId::EmailIdentifier.find_by(value: email)
      identifier.update!(provider: "google")
      StandardId::SocialIdentity.create!(account: legacy_account, identifier: identifier, provider: "google", subject: "g-existing")
      stub_google("email" => email, "email_verified" => true, "sub" => "g-existing")

      expect { post "/api/oauth/callback/google", params: { code: "c" } }
        .not_to change(StandardId::SocialIdentity, :count)
      expect(response).to have_http_status(:forbidden)
      expect(identifier.reload.provider).to eq("google")
    end
  end

  describe "new accounts refused by the policy are not left behind" do
    before { with_policy(->(**) { false }) }

    it "removes an account the API social callback just created" do
      stub_google("email" => email, "email_verified" => true, "sub" => "google-new")

      expect { post "/api/oauth/callback/google", params: { code: "code-3" } }
        .not_to change { [Account.count, StandardId::Identifier.count, StandardId::SocialIdentity.count] }
      expect(response).to have_http_status(:forbidden)
      expect(json["error_description"]).to eq(StandardId::LoginMethodDenied::DEFAULT_MESSAGE)
    end

    it "removes an account the web social callback just created" do
      stub_google("email" => email, "email_verified" => true, "sub" => "google-new-web")
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
        .to receive(:consume_oauth_request).and_return({ "params" => {}, "nonce" => nil })

      expect { http_get "/auth/callback/google", params: { state: "s", code: "c" } }
        .not_to change { [Account.count, StandardId::Identifier.count] }
      expect(response).to redirect_to("/login")
    end

    it "removes an account the passwordless_otp grant just registered" do
      # The dummy Account requires a name, which the built-in registration
      # does not supply.
      allow(StandardId.config.passwordless).to receive(:account_factory).and_return(
        ->(identifier:, **) {
          Account.create!(name: "New", email: identifier).tap do |account|
            StandardId::EmailIdentifier.create!(account: account, value: identifier)
          end
        }
      )
      StandardId::CodeChallenge.create!(
        realm: "authentication", channel: "email", target: email, code: "654321",
        expires_at: 10.minutes.from_now, ip_address: "127.0.0.1", user_agent: "RSpec"
      )

      expect {
        post token_path, params: { grant_type: "passwordless_otp", username: email, otp: "654321", connection: "email", client_id: "test-client" }, as: :json
      }.not_to change { [Account.count, StandardId::Identifier.count] }
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "does not consult the policy when the credential is wrong (no enumeration beyond the flow's own)" do
    create_account_with_password(email: email, password: password)
    policy = ->(**) { raise "must not be called" }
    with_policy(policy)

    http_post "/login", params: { login: { email: email, password: "wrong" } }
    expect(response).to have_http_status(:unprocessable_content)

    post token_path, params: { grant_type: "password", username: email, password: "wrong", client_id: "test-client" }, as: :json
    expect(response).to have_http_status(:bad_request)
    expect(json["error"]).to eq("invalid_grant")
  end

  describe "the inventory is complete" do
    it "has one row per flow StandardId::LoginMethodPolicy knows" do
      expect(PATHS.map { |p| p[:flow] }).to match_array(StandardId::LoginMethodPolicy::FLOWS)
    end

    # A grant either authenticates an account itself (gated) or derives a
    # token from an authentication that already passed the policy / has no
    # account (not gated). A new grant must be put in one of the two lists.
    GATED_GRANTS = {
      "password" => :oauth_password_grant,
      "passwordless_otp" => :oauth_passwordless_otp_grant,
      "refresh_token" => :oauth_refresh_token # with the recorded original method
    }.freeze
    DERIVED_GRANTS = %w[authorization_code client_credentials].freeze

    it "classifies every token grant" do
      expect(StandardId::Api::Oauth::TokensController::FLOW_STRATEGIES.keys).to match_array(GATED_GRANTS.keys + DERIVED_GRANTS)
    end

    it "gates exactly the grants that authenticate an account themselves" do
      StandardId::Api::Oauth::TokensController::FLOW_STRATEGIES.each do |grant, klass|
        context = klass.allocate.send(:login_method_policy_context)
        if GATED_GRANTS.key?(grant)
          expect(context).to include(flow: GATED_GRANTS[grant]), "#{grant} must be gated"
        else
          expect(context).to be_nil, "#{grant} derives from an earlier authentication and must not be gated"
        end
      end

      social = StandardId::Oauth::SocialFlow.allocate
      social.instance_variable_set(:@connection, "google")
      expect(social.send(:login_method_policy_context)).to eq(auth_method: :social, provider: "google", flow: :oauth_social_callback)
    end

    # Every place in app/ and lib/ that creates a session row or signs an
    # account in. Each is gated directly, or only reachable through a gated
    # caller (noted). A new call site fails this until it is classified.
    KNOWN_SESSION_CALL_SITES = {
      "app/controllers/concerns/standard_id/web_authentication.rb" => 1, # :web_password
      "app/controllers/standard_id/web/login_controller.rb" => 1, # -> WebAuthentication#sign_in_account
      "app/controllers/standard_id/web/login_verify_controller.rb" => 1, # :web_passwordless
      "app/controllers/standard_id/web/signup_controller.rb" => 1, # :web_signup
      "app/controllers/standard_id/web/auth/callback/providers_controller.rb" => 1, # :web_social
      "lib/standard_id/web/session_manager.rb" => 2, # sign_in_account (gated) + remember-me (:web_remember_me)
      "lib/standard_id/web/token_manager.rb" => 1, # only via Web::SessionManager
      "lib/standard_id/api/token_manager.rb" => 3, # :api_device_session / :api_service_session
      "lib/standard_id/oauth/token_grant_flow.rb" => 1, # after enforce_login_method_policy!
      "lib/standard_id/oauth/oauth_session_persistence.rb" => 2, # only via TokenGrantFlow
      "lib/standard_id/testing/request_helpers.rb" => 1 # test helper shipped to hosts, not a runtime path
    }.freeze

    SESSION_CALL_PATTERN = /
      \b(?:BrowserSession|DeviceSession|ServiceSession|session_class)\.create!?\(
      | \bcreate_browser_session\(
      | OauthSessionPersistence\.persist!
      | \bsign_in_account\(
    /x

    it "knows every session-creating call site" do
      root = StandardId::Engine.root
      found = Hash.new(0)
      Dir[root.join("{app,lib}/**/*.rb")].each do |file|
        File.foreach(file) do |line|
          next if line.lstrip.start_with?("#", "def ")
          next unless line.match?(SESSION_CALL_PATTERN)

          found[Pathname(file).relative_path_from(root).to_s] += 1
        end
      end

      expect(found).to eq(KNOWN_SESSION_CALL_SITES)
    end
  end
end
