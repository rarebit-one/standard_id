require "rails_helper"

# Core hooks for social providers: the callback's RFC 9207 `iss` reaches the
# provider as `callback_iss:`, and a provider that opts in with
# `supports_pkce?` gets a core-generated PKCE verifier, stored server-held with
# the flow's state, whose S256 challenge went out in the authorization URL.
RSpec.describe "Social callback iss and core-managed PKCE", type: :request do
  let(:email) { "pkce-#{SecureRandom.hex(4)}@example.com" }

  # Records what core passes; behaves like a minimal OIDC provider.
  let(:pkce_provider) do
    Class.new(StandardId::Providers::Base) do
      class << self
        attr_accessor :authorization_options, :user_info_options, :user_email

        def provider_name = "pkce_probe"
        def supports_pkce? = true
        def supported_authorization_params = [:nonce]

        def authorization_url(state:, redirect_uri:, **options)
          self.authorization_options = options
          build_authorization_url(endpoint: "https://idp.example.com/authorize", client_id: "probe-client",
                                  redirect_uri:, state:, options:)
        end

        def get_user_info(**options)
          self.user_info_options = options
          build_response({ "sub" => "probe-sub", "email" => user_email, "email_verified" => true })
        end
      end
    end
  end

  let(:plain_provider) do
    Class.new(StandardId::Providers::Base) do
      class << self
        attr_accessor :authorization_options, :user_info_options, :user_email

        def provider_name = "plain_probe"

        def authorization_url(state:, redirect_uri:, **options)
          self.authorization_options = options
          build_authorization_url(endpoint: "https://plain.example.com/authorize", client_id: "plain-client",
                                  redirect_uri:, state:, options:)
        end

        def get_user_info(**options)
          self.user_info_options = options
          build_response({ "sub" => "plain-sub", "email" => user_email, "email_verified" => true })
        end
      end
    end
  end

  around do |example|
    StandardId::ProviderRegistry.register(:pkce_probe, pkce_provider)
    StandardId::ProviderRegistry.register(:plain_probe, plain_provider)
    example.run
  ensure
    StandardId::ProviderRegistry.providers.delete("pkce_probe")
    StandardId::ProviderRegistry.providers.delete("plain_probe")
  end

  before do
    allow(StandardId.config).to receive(:account_class_name).and_return("Account")
    pkce_provider.user_email = email
    plain_provider.user_email = email
  end

  def start_login(connection)
    http_post "/login", params: { connection: connection, redirect_uri: "/after", login: { email: "", password: "" } }
    expect(response).to have_http_status(:found)
    Rack::Utils.parse_query(URI.parse(response.location).query)
  end

  describe "web flow, provider opted in to PKCE" do
    it "sends the S256 challenge and passes back the matching verifier and the callback iss" do
      query = start_login("pkce_probe")

      expect(query["code_challenge_method"]).to eq("S256")
      expect(query["code_challenge"]).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(query).not_to have_key("code_verifier")
      expect(pkce_provider.authorization_options).to include(code_challenge: query["code_challenge"], code_challenge_method: "S256")

      http_get "/auth/callback/pkce_probe", params: { state: query["state"], code: "auth-code", iss: "https://idp.example.com" }

      received = pkce_provider.user_info_options
      expect(received[:code]).to eq("auth-code")
      expect(received[:callback_iss]).to eq("https://idp.example.com")
      expect(received[:nonce]).to eq(query["nonce"])
      expect(received[:code_verifier]).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(pkce_provider.pkce_s256_challenge(received[:code_verifier])).to eq(query["code_challenge"])
      expect(response).to redirect_to("/after")
    end

    it "generates a fresh verifier per sign-in" do
      first = start_login("pkce_probe")["code_challenge"]
      second = start_login("pkce_probe")["code_challenge"]

      expect(first).not_to eq(second)
    end

    it "omits callback_iss when the redirect carries none, or a non-String" do
      query = start_login("pkce_probe")
      http_get "/auth/callback/pkce_probe", params: { state: query["state"], code: "auth-code" }
      expect(pkce_provider.user_info_options).not_to have_key(:callback_iss)

      query = start_login("pkce_probe")
      http_get "/auth/callback/pkce_probe", params: { state: query["state"], code: "auth-code", iss: ["https://idp.example.com"] }
      expect(pkce_provider.user_info_options).not_to have_key(:callback_iss)
    end

    it "refuses the callback, before calling the provider, when the stored request has no verifier" do
      query = start_login("plain_probe") # state stored without a verifier

      http_get "/auth/callback/pkce_probe", params: { state: query["state"], code: "auth-code" }

      expect(pkce_provider.user_info_options).to be_nil
      expect(response).to redirect_to(standard_id_web.login_path(redirect_uri: "/after"))
      expect(flash[:alert]).to include("Missing PKCE verifier")
    end
  end

  describe "web flow, provider not opted in" do
    it "sends no challenge and passes no verifier, but still passes the callback iss" do
      query = start_login("plain_probe")

      expect(query).not_to have_key("code_challenge")
      expect(query).not_to have_key("code_challenge_method")
      expect(plain_provider.authorization_options).not_to have_key(:code_challenge)

      http_get "/auth/callback/plain_probe", params: { state: query["state"], code: "auth-code", iss: "https://plain.example.com" }

      expect(plain_provider.user_info_options).not_to have_key(:code_verifier)
      expect(plain_provider.user_info_options[:callback_iss]).to eq("https://plain.example.com")
      expect(response).to redirect_to("/after")
    end

    it "keeps a 0.45-style provider that names only the classic kwargs working" do
      legacy = Class.new(StandardId::Providers::Base) do
        def self.provider_name = "plain_probe"
        def self.authorization_url(state:, redirect_uri:, **_options) = "https://legacy.example.com/authorize?state=#{state}"

        def self.get_user_info(code: nil, id_token: nil, access_token: nil, redirect_uri: nil, nonce: nil, **_options)
          build_response({ "sub" => "legacy-sub", "email" => "legacy-#{code}@example.com", "email_verified" => true })
        end
      end
      StandardId::ProviderRegistry.register(:plain_probe, legacy)

      state = Rack::Utils.parse_query(URI.parse(start_login_location("plain_probe")).query)["state"]
      http_get "/auth/callback/plain_probe", params: { state: state, code: "x1", iss: "https://legacy.example.com" }

      expect(response).to redirect_to("/after")
      expect(Account.find_by(email: "legacy-x1@example.com")).to be_present
    end
  end

  describe "API callback" do
    it "passes the request's iss but never a code_verifier, even a client-supplied one" do
      post "/api/oauth/callback/pkce_probe", params: { code: "c", iss: "https://idp.example.com", code_verifier: "client-chosen" }

      expect(pkce_provider.user_info_options[:callback_iss]).to eq("https://idp.example.com")
      expect(pkce_provider.user_info_options).not_to have_key(:code_verifier)
    end

    it "does not forward iss as host attribution" do
      forwarded = nil
      subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_COMPLETED) { |event| forwarded = event[:original_request_params] }

      post "/api/oauth/callback/plain_probe", params: { code: "c", iss: "https://plain.example.com", utm_source: "x" }

      expect(response).to have_http_status(:ok)
      expect(forwarded).to eq("utm_source" => "x")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end
  end

  describe "API social login grant" do
    it "refuses to start a sign-in for a provider that requires core-managed PKCE" do
      grant = StandardId::Oauth::Subflows::SocialLoginGrant.new(
        client_id: "c", redirect_uri: "https://app.example.com/cb", connection: "pkce_probe", base_url: "https://auth.example.com"
      )

      expect { grant.call }.to raise_error(StandardId::InvalidRequestError, /requires the web login flow/)
      expect(pkce_provider.authorization_options).to be_nil
    end
  end

  def start_login_location(connection)
    http_post "/login", params: { connection: connection, redirect_uri: "/after", login: { email: "", password: "" } }
    response.location
  end
end
