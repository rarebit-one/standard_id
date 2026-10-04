require "rails_helper"

# 0.45 pre-release follow-ups to the deferred social link (#363):
#
# 1. SOCIAL_ACCOUNT_LINKED is published only after the link has committed.
# 2. The web callback writes the link only after its redirect is in place.
# 3. A refused request's new account is neither adopted by, nor removed from
#    under, a concurrent login for the same email.
RSpec.describe "Social link commit", type: :request do
  let(:email) { "link-#{SecureRandom.hex(4)}@example.com" }
  let(:web_callback) { -> { http_get "/auth/callback/google", params: { state: "s", code: "c" } } }
  let(:api_callback) { -> { post "/api/oauth/callback/google", params: { code: "c" } } }

  before do
    allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
    allow(StandardId.config).to receive(:google_client_secret).and_return("google-secret")
    allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
      .to receive(:consume_oauth_request).and_return({ "params" => {}, "nonce" => nil })
  end

  def stub_google(sub, address = email)
    allow(StandardId::Providers::Google).to receive(:get_user_info).and_return(
      { user_info: { "email" => address, "email_verified" => true, "sub" => sub }, tokens: { access_token: "t" } }.with_indifferent_access
    )
  end

  def with_policy(policy)
    allow(StandardId.config).to receive(:login_method_policy).and_return(policy)
  end

  def json
    JSON.parse(response.body)
  end

  # Collects SOCIAL_ACCOUNT_LINKED, noting whether the link row was already
  # committed when the event fired.
  def capture_linked_events(subject)
    events = []
    subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_ACCOUNT_LINKED) do |event|
      events << { account: event[:account], link_written: StandardId::SocialIdentity.exists?(provider: "google", subject: subject) }
    end
    yield
    events
  ensure
    StandardId::Events.unsubscribe(subscription)
  end

  # A pre-provider-tracking identifier: linking writes the sub AND backfills
  # the provider.
  def legacy_account
    @legacy_account ||= Account.create!(name: "Legacy", email: email).tap do |account|
      StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
    end
  end

  describe "SOCIAL_ACCOUNT_LINKED" do
    before { legacy_account }

    { "web" => :web_callback, "API" => :api_callback }.each do |label, callback|
      it "#{label}: is published once, after the link is written, for an accepted login" do
        stub_google("g-linked-#{label}")

        events = capture_linked_events("g-linked-#{label}") { instance_exec(&send(callback)) }

        expect(events.size).to eq(1)
        expect(events.first).to include(account: legacy_account, link_written: true)
      end

      it "#{label}: a subscriber that raises does not fail the committed login" do
        stub_google("g-raise-#{label}")
        subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_ACCOUNT_LINKED) { raise "subscriber boom" }
        allow(Rails.error).to receive(:report)

        begin
          instance_exec(&send(callback))
        ensure
          StandardId::Events.unsubscribe(subscription)
        end

        expect(StandardId::SocialIdentity.exists?(provider: "google", subject: "g-raise-#{label}")).to be(true)
        expect(Rails.error).to have_received(:report).with(an_instance_of(RuntimeError), hash_including(handled: true))
        if label == "API"
          expect(response).to have_http_status(:ok)
          expect(json).to include("access_token")
        else
          expect(response).to have_http_status(:redirect)
          expect(response.location).not_to include("/login")
        end
      end

      it "#{label}: is not published when the policy refuses the login" do
        stub_google("g-refused-#{label}")
        with_policy(->(**) { false })

        events = capture_linked_events("g-refused-#{label}") { instance_exec(&send(callback)) }

        expect(events).to be_empty
        expect(StandardId::SocialIdentity.where(subject: "g-refused-#{label}")).to be_empty
      end
    end

    it "web: is not published when before_sign_in refuses the login" do
      stub_google("g-hook")
      allow(StandardId.config).to receive(:before_sign_in).and_return(->(_a, _r, _c) { { error: "Nope" } })

      expect(capture_linked_events("g-hook") { web_callback.call }).to be_empty
      expect(response).to redirect_to("/login")
    end

    it "API: is not published when a scope check refuses the login" do
      allow(StandardId.config.social).to receive(:available_scopes).and_return(["openid"])
      stub_google("g-scope")

      expect(capture_linked_events("g-scope") { post "/api/oauth/callback/google", params: { code: "c", scope: "admin" } }).to be_empty
      expect(response).to have_http_status(:bad_request)
    end

    # The backfill and the (provider, sub) insert commit together: when the
    # insert fails, the backfill is rolled back with it. (Codex on #363:
    # "Keep rollback state until the link fully commits".)
    it "is not published, and the provider backfill is rolled back, when writing the link fails" do
      stub_google("g-insert-fails")
      allow(StandardId::SocialIdentity).to receive(:find_or_create_by!).and_raise(ActiveRecord::StatementInvalid, "insert failed")

      events = capture_linked_events("g-insert-fails") do
        expect { api_callback.call }.to raise_error(ActiveRecord::StatementInvalid)
      end

      expect(events).to be_empty
      expect(StandardId::EmailIdentifier.find_by(value: email).provider).to be_nil
    end
  end

  # A concurrent callback for the same (provider, sub) commits its link to a
  # DIFFERENT account before this request's find_or_create_by! SELECT, so the
  # existing row comes back without a unique violation. It must be refused
  # like the RecordNotUnique path, not adopted.
  describe "a (provider, sub) row committed concurrently for another account" do
    before { legacy_account }

    def other_account
      @other_account ||= Account.create!(name: "Other", email: "other-#{SecureRandom.hex(4)}@example.com").tap do |account|
        StandardId::EmailIdentifier.create!(account: account, value: account.email, verified_at: Time.current)
      end
    end

    def commit_rival_link(subject)
      rival = StandardId::Identifier.find_by!(account_id: other_account.id)
      ->(*) {
        StandardId::SocialIdentity.create!(provider: "google", subject: subject, account: other_account, identifier: rival)
        nil
      }
    end

    it "web: fails with a retryable error and leaves the rival link and no session on the matched account" do
      stub_google("g-rival-web")
      allow(StandardId.config).to receive(:before_sign_in).and_return(commit_rival_link("g-rival-web"))

      web_callback.call

      expect(response).to redirect_to("/login")
      expect(StandardId::SocialIdentity.find_by(subject: "g-rival-web").account_id).to eq(other_account.id)
      expect(StandardId::Session.where(account_id: legacy_account.id).active).to be_empty
      expect(StandardId::Identifier.find_by!(account_id: legacy_account.id).provider).to be_nil
    end

    it "API: answers invalid_grant and revokes what it issued for the matched account" do
      stub_google("g-rival-api")
      with_policy(->(account:) {
        commit_rival_link("g-rival-api").call if account.id == legacy_account.id
        true
      })

      api_callback.call

      expect(response).to have_http_status(:bad_request)
      expect(json).to include("error" => "invalid_grant")
      expect(StandardId::SocialIdentity.find_by(subject: "g-rival-api").account_id).to eq(other_account.id)
      expect(StandardId::RefreshToken.active.where(account_id: legacy_account.id)).to be_empty
    end
  end

  describe "web: the link is written only after the redirect" do
    before { legacy_account }

    it "leaves no link, no backfill and no live session when the redirect itself raises" do
      stub_google("g-bad-redirect")
      # A cross-host URL that is not on allowed_redirect_url_prefixes:
      # redirect_to refuses it (open-redirect protection; the dummy app runs
      # Rails' default action_on_open_redirect = :raise).
      allow(StandardId.config).to receive(:after_sign_in).and_return(->(_a, _r, _c) { "https://elsewhere.example/landing" })

      events = capture_linked_events("g-bad-redirect") do
        expect { web_callback.call }.to raise_error(ActionController::Redirecting::UnsafeRedirectError)
      end

      expect(events).to be_empty
      expect(StandardId::SocialIdentity.where(subject: "g-bad-redirect")).to be_empty
      expect(StandardId::EmailIdentifier.find_by(value: email).provider).to be_nil
      expect(StandardId::BrowserSession.where(account_id: legacy_account.id).active).to be_empty
    end
  end

  # Request A creates a new account, then is refused and removes it
  # (AccountCleanup.destroy_newly_created!). Request B, for the same email,
  # finds that account by email in the meantime.
  describe "a refused request's new account and a concurrent login for the same email" do
    let(:new_email) { "new-#{email}" }

    # B signs in to A's account before A's refusal removes it: the account
    # has been adopted and is kept. Simulated by B's session appearing from
    # inside A's policy check, the point at which A is about to be refused.
    { "web" => :web_callback, "API" => :api_callback }.each do |label, callback|
      it "#{label}: A keeps the account when B has already signed in to it" do
        stub_google("g-a-#{label}", new_email)
        b_session = nil
        with_policy(->(account:) {
          b_session = StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.2", user_agent: "B", expires_at: 1.hour.from_now)
          false
        })

        instance_exec(&send(callback))

        expect(b_session).to be_present
        expect(Account.exists?(b_session.account_id)).to be(true)
        expect(b_session.reload.revoked_at).to be_nil
        expect(StandardId::EmailIdentifier.find_by(value: new_email)).to be_present
      end
    end

    # A's own tokens never count as a concurrent login: here the grant raises
    # after it wrote them, so no token response comes back, and the callback
    # revokes them from the flow before the cleanup checks for adoption.
    it "API: A still removes its account when the grant fails after issuing tokens" do
      stub_google("g-a-issued", new_email)
      subscription = StandardId::Events.subscribe(StandardId::Events::OAUTH_TOKEN_ISSUED) { |_e| raise "subscriber bug" }

      expect {
        expect { api_callback.call }.to raise_error(RuntimeError, "subscriber bug")
      }.not_to change { [Account.count, StandardId::Identifier.count, StandardId::RefreshToken.count, StandardId::Session.count] }
    ensure
      StandardId::Events.unsubscribe(subscription)
    end

    # A's removal runs first (B has no session yet): B must not end up
    # signed in to, or linked to, the removed account; it fails cleanly and
    # a retry creates a fresh account.
    def doomed_account
      @doomed_account ||= Account.create!(name: "Doomed", email: new_email).tap do |account|
        StandardId::EmailIdentifier.create!(account: account, value: new_email, provider: "google", verified_at: Time.current)
      end
    end

    it "web: B fails with a retryable error, and a retry signs in to a fresh account" do
      stub_google("g-b-web", new_email)
      doomed = doomed_account
      allow(StandardId.config).to receive(:before_sign_in).and_return(->(account, _r, _c) {
        StandardId::AccountCleanup.destroy_newly_created!(account) if account.id == doomed.id
        nil
      })

      web_callback.call

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to include("Please try again")
      expect(Account.exists?(doomed.id)).to be(false)
      expect(StandardId::SocialIdentity.where(subject: "g-b-web")).to be_empty

      web_callback.call # the retry

      fresh_id = StandardId::EmailIdentifier.find_by(value: new_email).account_id
      expect(fresh_id).not_to eq(doomed.id)
      expect(response.location).not_to end_with("/login")
      expect(StandardId::SocialIdentity.find_by(subject: "g-b-web").account_id).to eq(fresh_id)
    end

    it "API: B fails with invalid_grant, and a retry gets tokens for a fresh account" do
      stub_google("g-b-api", new_email)
      doomed = doomed_account
      with_policy(->(account:) {
        StandardId::AccountCleanup.destroy_newly_created!(account) if account.id == doomed.id
        true
      })

      api_callback.call

      expect(response).to have_http_status(:bad_request)
      expect(json).to include("error" => "invalid_grant", "error_description" => StandardId::SocialAuthentication::SOCIAL_RETRY_MESSAGE)
      expect(Account.exists?(doomed.id)).to be(false)
      expect(StandardId::SocialIdentity.where(subject: "g-b-api")).to be_empty

      api_callback.call # the retry

      expect(response).to have_http_status(:ok)
      fresh_id = StandardId::EmailIdentifier.find_by(value: new_email).account_id
      expect(fresh_id).not_to eq(doomed.id)
      expect(StandardId::SocialIdentity.find_by(subject: "g-b-api").account_id).to eq(fresh_id)
    end

    # The commit itself re-checks the account under the row lock: if the
    # account is removed after B's session exists (possible only where the
    # host has no foreign key on sessions.account_id), the link is not
    # written and B's redirect is replaced by /login.
    it "web: B's commit refuses an account removed after its session was created" do
      stub_google("g-b-commit", new_email)
      doomed = doomed_account
      allow(StandardId::AccountCleanup).to receive(:adopted?).and_return(false) # force the removal through
      allow(StandardId.config).to receive(:after_sign_in).and_return(->(account, _r, _c) {
        StandardId::AccountCleanup.destroy_newly_created!(account)
        nil
      })

      events = capture_linked_events("g-b-commit") { web_callback.call }

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to include("Please try again")
      expect(flash[:notice]).to be_nil
      expect(events).to be_empty
      expect(Account.exists?(doomed.id)).to be(false)
      expect(StandardId::SocialIdentity.where(subject: "g-b-commit")).to be_empty
    end
  end
end
