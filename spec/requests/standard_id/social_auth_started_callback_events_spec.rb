require "rails_helper"

# social.auth.started (the browser is sent to the provider) and
# social.auth.callback_received (the provider's answer reaches a callback).
RSpec.describe "social.auth.started and social.auth.callback_received", type: :request do
  let(:email) { "social-events-#{SecureRandom.hex(4)}@example.com" }

  let(:probe) do
    Class.new(StandardId::Providers::Base) do
      class << self
        attr_accessor :user_email

        def provider_name = "events_probe"
        def supported_authorization_params = [:nonce]

        def authorization_url(state:, redirect_uri:, **options)
          build_authorization_url(endpoint: "https://idp.example.com/authorize", client_id: "probe-client",
                                  redirect_uri:, state:, options:)
        end

        def get_user_info(**)
          build_response({ "sub" => "probe-sub", "email" => user_email, "email_verified" => true })
        end
      end
    end
  end

  let(:events) { [] }

  around do |example|
    StandardId::ProviderRegistry.register(:events_probe, probe)
    subs = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_STARTED, StandardId::Events::SOCIAL_CALLBACK_RECEIVED) do |e|
      events << [e.short_name, e.payload]
    end
    example.run
  ensure
    StandardId::Events.unsubscribe(subs)
    StandardId::ProviderRegistry.providers.delete("events_probe")
  end

  before do
    allow(StandardId.config).to receive(:account_class_name).and_return("Account")
    probe.user_email = email
  end

  def fired = events.map(&:first)

  def payload_for(name) = events.find { |n, _| n == name }&.last

  def start_login
    http_post "/login", params: { connection: "events_probe", redirect_uri: "/after", login: { email: "", password: "" } }
    Rack::Utils.parse_query(URI.parse(response.location).query)
  end

  describe "web flow" do
    it "publishes started with the provider and callback URL, never the state or nonce" do
      query = start_login

      expect(fired).to eq([StandardId::Events::SOCIAL_AUTH_STARTED])
      started = payload_for(StandardId::Events::SOCIAL_AUTH_STARTED)
      expect(started).to include(provider: "events_probe", flow: "web")
      expect(started[:redirect_uri]).to end_with(probe.callback_path)
      expect(started.values.map(&:to_s)).not_to include(query["state"], query["nonce"])
    end

    it "publishes callback_received with the provider, never the code or state" do
      query = start_login
      events.clear

      http_get "/auth/callback/events_probe", params: { state: query["state"], code: "auth-code-123" }

      expect(response).to redirect_to("/after")
      expect(fired).to eq([StandardId::Events::SOCIAL_CALLBACK_RECEIVED])
      received = payload_for(StandardId::Events::SOCIAL_CALLBACK_RECEIVED)
      expect(received).to include(provider: "events_probe", flow: "web")
      expect(received[:error]).to be_nil
      expect(received.values.map(&:to_s)).not_to include("auth-code-123", query["state"])
    end

    it "reports the provider's error when the user cancels" do
      query = start_login
      events.clear

      http_get "/auth/callback/events_probe", params: { state: query["state"], error: "access_denied" }

      expect(payload_for(StandardId::Events::SOCIAL_CALLBACK_RECEIVED)).to include(error: "access_denied")
    end

    it "publishes neither for a password login" do
      create_account_with_password(email: email, password: "Sup3r-secret!")
      http_post "/login", params: { login: { email: email, password: "Sup3r-secret!" }, redirect_uri: "/after" }

      expect(events).to be_empty
    end
  end

  describe "API callback" do
    it "publishes callback_received with the api flow" do
      post "/api/oauth/callback/events_probe", params: { code: "api-code-456" }

      received = payload_for(StandardId::Events::SOCIAL_CALLBACK_RECEIVED)
      expect(received).to include(provider: "events_probe", flow: "api")
      expect(received.values.map(&:to_s)).not_to include("api-code-456")
    end
  end

  describe "/authorize with a social connection" do
    let(:client) do
      StandardId::ClientApplication.create!(
        owner: Account.create!(name: "Owner", email: "owner-#{SecureRandom.hex(4)}@example.com"),
        name: "Social Client",
        client_id: "social_client_#{SecureRandom.hex(4)}",
        redirect_uris: "https://example.com/callback",
        scopes: "read",
        require_pkce: false,
        code_challenge_methods: nil
      )
    end

    it "publishes started, and no authorization grant until the callback" do
      granted = []
      sub = StandardId::Events.subscribe(StandardId::Events::OAUTH_AUTHORIZATION_GRANTED) { |e| granted << e }
      begin
        http_get "/api/authorize", params: {
          response_type: "code", client_id: client.client_id, redirect_uri: "https://example.com/callback",
          connection: "events_probe", state: "client-state"
        }
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      expect(response.location).to start_with("https://idp.example.com/authorize")
      started = payload_for(StandardId::Events::SOCIAL_AUTH_STARTED)
      expect(started).to include(provider: "events_probe", flow: "oauth_authorize", client_id: client.client_id)
      expect(started[:redirect_uri]).to end_with("/api/oauth/callback/events_probe")
      expect(granted).to be_empty
    end
  end

  it "stays auditable through the social.* family" do
    names = [StandardId::Events::SOCIAL_AUTH_STARTED, StandardId::Events::SOCIAL_CALLBACK_RECEIVED].map do |name|
      StandardId::Events.namespaced_event_name(name)
    end

    names.each do |name|
      expect(StandardId::Events.auditable.any? { |p| p.is_a?(Regexp) ? p.match?(name) : p == name }).to be(true)
    end
  end
end
