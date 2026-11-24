require "rails_helper"

# oauth.authorization.requested / granted / denied around /authorize and the
# consent screen.
RSpec.describe "OAuth authorization events", type: :request do
  let(:client_owner) { Account.create!(name: "Owner", email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:require_consent) { false }
  let(:client) do
    StandardId::ClientApplication.create!(
      owner: client_owner,
      name: "Events Client",
      client_id: "events_client_#{SecureRandom.hex(4)}",
      redirect_uris: "https://example.com/callback",
      scopes: "read write",
      require_consent: require_consent,
      require_pkce: false,
      code_challenge_methods: nil
    )
  end
  let(:account) { Account.create!(name: "Authorizer", email: "authorizer-#{SecureRandom.hex(4)}@example.com") }
  let(:authorize_params) do
    {
      response_type: "code",
      client_id: client.client_id,
      redirect_uri: "https://example.com/callback",
      scope: "read",
      state: "events_state_123"
    }
  end

  let(:events) { [] }
  let(:names) do
    [
      StandardId::Events::OAUTH_AUTHORIZATION_REQUESTED,
      StandardId::Events::OAUTH_AUTHORIZATION_GRANTED,
      StandardId::Events::OAUTH_AUTHORIZATION_DENIED
    ]
  end

  around do |example|
    subs = StandardId::Events.subscribe(*names) { |e| events << [e.short_name, e.payload] }
    example.run
  ensure
    StandardId::Events.unsubscribe(subs)
  end

  def sign_in
    session = StandardId::BrowserSession.create!(
      account: account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 1.day.from_now
    )
    post util_session_path, params: { session_token: session.token }
  end

  def fired = events.map(&:first)

  def payload_for(name) = events.find { |n, _| n == name }&.last

  before { sign_in }

  context "with a client that needs no consent" do
    it "publishes requested, then granted, when a code is issued" do
      http_get "/api/authorize", params: authorize_params

      expect(response.location).to include("code=")
      expect(fired).to eq([StandardId::Events::OAUTH_AUTHORIZATION_REQUESTED, StandardId::Events::OAUTH_AUTHORIZATION_GRANTED])

      requested = payload_for(StandardId::Events::OAUTH_AUTHORIZATION_REQUESTED)
      expect(requested).to include(client_id: client.client_id, response_type: "code", scope: "read",
                                   redirect_uri: "https://example.com/callback")
      expect(requested[:account].id).to eq(account.id)

      granted = payload_for(StandardId::Events::OAUTH_AUTHORIZATION_GRANTED)
      expect(granted).to include(client_id: client.client_id, response_type: "code", scope: "read",
                                 redirect_uri: "https://example.com/callback")
      expect(granted[:account].id).to eq(account.id)
    end

    it "never carries the code or the state" do
      http_get "/api/authorize", params: authorize_params
      code = Rack::Utils.parse_query(URI.parse(response.location).query)["code"]

      values = events.flat_map { |_, payload| payload.values.map(&:to_s) }
      expect(values).not_to include(code, "events_state_123")
    end

    it "publishes granted for an implicit token too" do
      http_get "/api/authorize", params: authorize_params.merge(response_type: "token")

      expect(response.location).to include("access_token=")
      expect(payload_for(StandardId::Events::OAUTH_AUTHORIZATION_GRANTED)).to include(response_type: "token")
    end

    it "publishes requested but not granted when the request is refused" do
      client.update!(require_pkce: true, code_challenge_methods: "S256")

      http_get "/api/authorize", params: authorize_params # no code_challenge

      expect(response.location.to_s).not_to include("code=")

      expect(fired).to eq([StandardId::Events::OAUTH_AUTHORIZATION_REQUESTED])
    end

    it "publishes nothing for an unknown client" do
      http_get "/api/authorize", params: authorize_params.merge(client_id: "no-such-client")

      expect(events).to be_empty
    end
  end

  context "with a require_consent client" do
    let(:require_consent) { true }

    def consent_request_token
      http_get "/api/authorize", params: authorize_params
      Rack::Utils.parse_query(URI.parse(response.location).query)["consent_request"]
    end

    it "publishes requested once at /authorize, then granted on approve" do
      token = consent_request_token
      expect(fired).to eq([StandardId::Events::OAUTH_AUTHORIZATION_REQUESTED])

      http_post "/consent", params: { decision: "approve", consent_request: token }

      expect(response.location).to include("code=")
      expect(fired).to eq([StandardId::Events::OAUTH_AUTHORIZATION_REQUESTED, StandardId::Events::OAUTH_AUTHORIZATION_GRANTED])
    end

    it "publishes denied, and not granted, on deny" do
      token = consent_request_token

      http_post "/consent", params: { decision: "deny", consent_request: token }

      expect(response.location).to include("error=access_denied")
      expect(fired).to eq([StandardId::Events::OAUTH_AUTHORIZATION_REQUESTED, StandardId::Events::OAUTH_AUTHORIZATION_DENIED])
      denied = payload_for(StandardId::Events::OAUTH_AUTHORIZATION_DENIED)
      expect(denied).to include(client_id: client.client_id, scope: "read", redirect_uri: "https://example.com/callback",
                                reason: "access_denied")
      expect(denied[:account].id).to eq(account.id)
    end
  end

  it "is auditable for granted and denied only" do
    auditable = StandardId::Events.auditable
    expect(auditable).to include("standard_id.oauth.authorization.granted", "standard_id.oauth.authorization.denied")
    expect(auditable).not_to include("standard_id.oauth.authorization.requested")
  end
end
