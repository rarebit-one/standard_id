require "rails_helper"

RSpec.describe StandardId::TokenMinter do
  let(:account) { Account.create!(name: "Minted", email: "mint-#{SecureRandom.hex(4)}@example.com") }

  def decode(token) = StandardId::JwtService.decode(token)

  def capture(*events)
    seen = []
    subs = events.map { |e| StandardId::Events.subscribe(e) { |ev| seen << ev } }
    yield
    seen
  ensure
    subs.each { |s| StandardId::Events.unsubscribe(s) }
  end

  it "mints an access token with the standard claims and the host's grant_type" do
    result = described_class.mint(account: account, audience: "harness", grant_type: "harness.mint", scopes: "profile permissions")

    payload = decode(result.access_token)
    expect(payload[:sub].to_s).to eq(account.id.to_s)
    expect(payload[:aud]).to eq("harness")
    expect(payload[:scope]).to eq("profile permissions")
    expect(payload[:grant_type]).to eq("harness.mint")
    expect(payload[:jti]).to eq(result.jti)
    expect(result.token_type).to eq("Bearer")
    expect(result.refresh_token).to be_nil
    expect(result.scope).to eq("profile permissions")
  end

  it "honours an explicit lifetime and otherwise the configured one" do
    short = described_class.mint(account: account, audience: "api", grant_type: "console.mint", expires_in: 5.minutes)
    expect(short.expires_in).to eq(300)

    default = described_class.mint(account: account, audience: "api", grant_type: "console.mint")
    expect(default.expires_in).to eq(StandardId.config.oauth.default_token_lifetime)
  end

  it "merges host claims last but never over a reserved key or base field" do
    result = described_class.mint(
      account: account, audience: "harness", grant_type: "harness.mint",
      claims: { permissions: %w[harness:read], sub: "impostor", aud: "elsewhere", claims: "x" }
    )

    payload = decode(result.access_token)
    expect(payload[:permissions]).to eq(%w[harness:read])
    expect(payload[:sub].to_s).to eq(account.id.to_s)
    expect(payload[:aud]).to eq("harness")
    expect(payload).not_to have_key(:claims)
  end

  it "runs scope_claims / claim_resolvers with the same context as the token endpoint" do
    allow(StandardId.config.oauth).to receive(:scope_claims).and_return({ "profile" => [:email, :who] })
    allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({
      email: ->(account:) { account.email },
      who: ->(audience:, client:) { "#{audience}:#{client.inspect}" }
    })

    result = described_class.mint(account: account, audience: "harness", grant_type: "harness.mint", scopes: "profile")

    payload = decode(result.access_token)
    expect(payload[:email]).to eq(account.email)
    expect(payload[:who]).to eq("harness:nil")
  end

  it "refuses a non-positive expires_in rather than silently minting a default-lifetime token" do
    expect {
      described_class.mint(account: account, audience: "api", grant_type: "console.mint", expires_in: 0)
    }.to raise_error(StandardId::InvalidRequestError, /expires_in must be a positive/)
  end

  it "hands resolvers request: nil for a sessionless mint" do
    allow(StandardId.config.oauth).to receive(:scope_claims).and_return({ "profile" => [:ip] })
    allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({ ip: ->(request:) { request&.remote_ip || "none" } })

    result = described_class.mint(account: account, audience: "api", grant_type: "console.mint", scopes: "profile")

    expect(decode(result.access_token)[:ip]).to eq("none")
  end

  it "validates the audience against oauth.allowed_audiences" do
    allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(%w[api])

    expect {
      described_class.mint(account: account, audience: "harness", grant_type: "harness.mint")
    }.to raise_error(StandardId::InvalidRequestError, /Invalid audience: harness/)
  end

  it "fails closed when the audience is bound to a profile type the account lacks" do
    allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return({ "harness" => ["PlatformProfile"] })

    expect {
      described_class.mint(account: account, audience: "harness", grant_type: "harness.mint")
    }.to raise_error(StandardId::InvalidGrantError)
  end

  it "publishes OAUTH_TOKEN_ISSUING and OAUTH_TOKEN_ISSUED with the host's grant_type" do
    seen = capture(StandardId::Events::OAUTH_TOKEN_ISSUING, StandardId::Events::OAUTH_TOKEN_ISSUED) do
      described_class.mint(account: account, audience: "harness", grant_type: "harness.mint")
    end

    expect(seen.map(&:short_name)).to eq(%w[oauth.token.issuing oauth.token.issued])
    expect(seen.map { |e| e[:grant_type] }).to eq(%w[harness.mint harness.mint])
    expect(seen.last[:account]).to eq(account)
    expect(seen.last[:audience]).to eq("harness")
    expect(seen.last[:jti]).to be_present
  end

  it "is refused for a deactivated account by the AccountStatus guard, like every other mint" do
    account.deactivate!

    expect {
      described_class.mint(account: account, audience: "harness", grant_type: "harness.mint")
    }.to raise_error(StandardId::AccountDeactivatedError)
  end

  it "requires a persisted account and a grant_type" do
    expect { described_class.mint(account: nil, audience: "api", grant_type: "x") }
      .to raise_error(StandardId::InvalidGrantError, "Account is required")
    expect { described_class.mint(account: Account.new, audience: "api", grant_type: "x") }
      .to raise_error(StandardId::InvalidGrantError, "Account must be persisted")
    expect { described_class.mint(account: account, audience: "api", grant_type: "") }
      .to raise_error(StandardId::InvalidRequestError, "grant_type is required")
  end

  describe "refresh_token: true" do
    it "persists a refresh token, bound to the named client application when it exists" do
      client = StandardId::ClientApplication.create!(owner: account, name: "Console", redirect_uris: "https://c.example.com/cb")

      result = described_class.mint(
        account: account, audience: "api", grant_type: "console.mint", refresh_token: true, client_id: client.client_id
      )

      expect(result.refresh_token).to be_present
      record = StandardId::RefreshToken.find_by_jti(decode(result.refresh_token)[:jti])
      expect(record.account_id).to eq(account.id)
      expect(record.client_application_id).to eq(client.id)
      expect(record.session_id).to be_nil
    end

    it "requires a client_id, since the refresh grant matches on it" do
      expect {
        described_class.mint(account: account, audience: "api", grant_type: "console.mint", refresh_token: true)
      }.to raise_error(StandardId::InvalidRequestError, "client_id is required for a refreshable token")
    end

    it "leaves the token unbound and sessionless for a client_id that is not a registered application" do
      result = described_class.mint(account: account, audience: "api", grant_type: "console.mint", refresh_token: true, client_id: "console")

      record = StandardId::RefreshToken.find_by_jti(decode(result.refresh_token)[:jti])
      expect(record.client_application_id).to be_nil
      expect(record.session_id).to be_nil
    end

    it "records the host's auth lineage on the refresh token" do
      result = described_class.mint(
        account: account, audience: "api", grant_type: "console.mint", refresh_token: true, client_id: "console",
        auth_method: :password, auth_provider: nil
      )

      record = StandardId::RefreshToken.find_by_jti(decode(result.refresh_token)[:jti])
      expect(record.auth_method).to eq("password")
    end
  end

  it "is not reachable from the token endpoint as a grant_type" do
    expect(StandardId::Api::Oauth::TokensController::FLOW_STRATEGIES.values).not_to include(StandardId::Oauth::DirectMintFlow)
  end
end
