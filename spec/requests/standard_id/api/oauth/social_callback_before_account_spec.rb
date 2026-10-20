require "rails_helper"

# config.social.before_account, config.social.completion_before_mint and
# StandardId::RequestRefused on the API social callback: what a host needs to
# refuse a sign-in in its own error envelope before any account exists, and
# to run its completion subscriber before the mint, without subclassing the
# controller.
RSpec.describe "API social callback host hooks", type: :request do
  let(:email) { "hooks-#{SecureRandom.hex(4)}@example.com" }

  before do
    allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
    allow(StandardId::Providers::Google).to receive(:get_user_info).and_return(
      { user_info: { "email" => email, "email_verified" => true, "sub" => "g-#{SecureRandom.hex(4)}" }, tokens: { "id_token" => "t" } }.with_indifferent_access
    )
  end

  def json = JSON.parse(response.body)

  def capture(*names)
    seen = []
    subs = names.map { |n| StandardId::Events.subscribe(n) { |e| seen << e.short_name } }
    yield
    seen
  ensure
    StandardId::Events.unsubscribe(subs)
  end

  describe "before_account" do
    it "runs before find-or-create with the provider's context" do
      seen = nil
      allow(StandardId.config.social).to receive(:before_account).and_return(
        ->(provider:, social_info:, params:, request:) { seen = [provider, social_info["email"], params, request.path, Account.exists?(email: email)] }
      )

      post "/api/oauth/callback/google", params: { code: "c", region: "sg" }

      expect(response).to have_http_status(:ok)
      expect(seen).to eq(["google", email, { "region" => "sg" }, "/api/oauth/callback/google", false])
    end

    it "receives the requested audience and scopes, which the forwarded params strip" do
      seen = nil
      allow(StandardId.config.social).to receive(:before_account).and_return(->(audience:, scopes:, params:) { seen = [audience, scopes, params] })

      post "/api/oauth/callback/google", params: { code: "c", audience: "api", scope: "profile" }

      expect(seen).to eq(["api", "profile", {}])
    end

    it "refuses with the host's own response and leaves no account and no account events" do
      body = { "error" => { "code" => "REGION_BLOCKED", "message" => "Not here", "details" => nil } }
      allow(StandardId.config.social).to receive(:before_account).and_return(
        -> { raise StandardId::RequestRefused.new(status: :forbidden, body: body, headers: { "X-Refusal" => "region" }) }
      )

      events = capture(StandardId::Events::ACCOUNT_CREATED, StandardId::Events::SOCIAL_ACCOUNT_CREATED) do
        expect { post "/api/oauth/callback/google", params: { code: "c" } }.not_to change(Account, :count)
      end

      expect(response).to have_http_status(:forbidden)
      expect(json).to eq(body)
      expect(response.headers["X-Refusal"]).to eq("region")
      expect(events).to be_empty
    end
  end

  describe "RequestRefused from before_mint" do
    it "renders the host's response after the usual cleanup" do
      allow(StandardId.config.social).to receive(:before_mint).and_return(
        -> { raise StandardId::RequestRefused.new(status: 403, body: { error: { code: "ACCOUNT_PENDING_DELETION" } }) }
      )

      expect { post "/api/oauth/callback/google", params: { code: "c" } }.not_to change(Account, :count)

      expect(response).to have_http_status(:forbidden)
      expect(json.dig("error", "code")).to eq("ACCOUNT_PENDING_DELETION")
      expect(StandardId::RefreshToken.count).to eq(0)
    end
  end

  describe "completion_before_mint" do
    def order_of_events
      capture(StandardId::Events::SOCIAL_AUTH_COMPLETED, StandardId::Events::OAUTH_TOKEN_ISSUING) do
        post "/api/oauth/callback/google", params: { code: "c" }
      end
    end

    it "publishes SOCIAL_AUTH_COMPLETED after the mint by default" do
      expect(order_of_events).to eq(%w[oauth.token.issuing social.auth.completed])
    end

    it "publishes it after before_mint and before the mint when enabled" do
      allow(StandardId.config.social).to receive(:completion_before_mint).and_return(true)
      hook_ran_first = nil
      allow(StandardId.config.social).to receive(:before_mint).and_return(-> { hook_ran_first = true })

      expect(order_of_events).to eq(%w[social.auth.completed oauth.token.issuing])
      expect(hook_ran_first).to be(true)
      expect(response).to have_http_status(:ok)
    end

    it "lets a completion subscriber create what the audience binding needs, visible to the mint" do
      allow(StandardId.config.social).to receive(:completion_before_mint).and_return(true)
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return({ "api" => ["Provisioned"] })
      # The binding resolves only once the subscriber's write is visible on
      # the account the mint holds — which is what the reload is for.
      allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(
        ->(account:) { account if account.name == "provisioned" }
      )
      sub = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_COMPLETED) do |event|
        Account.find(event[:account].id).update!(name: "provisioned")
      end

      post "/api/oauth/callback/google", params: { code: "c", audience: "api" }

      expect(response).to have_http_status(:ok)
      expect(json["access_token"]).to be_present
    ensure
      StandardId::Events.unsubscribe(sub)
    end

    it "still removes a new account when the mint refuses after an early completion" do
      allow(StandardId.config.social).to receive(:completion_before_mint).and_return(true)
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return({ "api" => ["PlatformProfile"] })

      expect { post "/api/oauth/callback/google", params: { code: "c", audience: "api" } }.not_to change(Account, :count)
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe StandardId::RequestRefused do
    it "carries status, body and string-keyed headers, defaulting to none" do
      error = described_class.new(status: :forbidden, body: { a: 1 })
      expect([error.status, error.body, error.headers]).to eq([:forbidden, { a: 1 }, {}])
      expect(error.message).to eq("Request refused (forbidden)")
      expect(described_class.new(status: 403, body: nil, headers: [["X-A", "1"]]).headers).to eq("X-A" => "1")
    end
  end
end
