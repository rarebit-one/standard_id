require "rails_helper"

# StandardId::ResourceServer end to end, through the dummy app's
# Api::V1::McpController (`protected_resource "mcp", scopes: %w[mcp]`).
RSpec.describe "StandardId::ResourceServer", type: :request do
  let(:account) { Account.create!(name: "MCP User", email: "mcp-#{SecureRandom.hex(4)}@example.com") }
  let(:metadata_url) { "http://www.example.com/.well-known/oauth-protected-resource/mcp" }

  before do
    allow(StandardId.config.oauth).to receive(:protected_resources).and_return("mcp" => { path: "/mcp" })
    allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return({})
    allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(nil)
  end

  def challenge
    response.headers["WWW-Authenticate"]
  end

  it "serves a token minted for the audience with a required scope" do
    as_service(account: account, scope: "mcp mcp:read", extra: { aud: "mcp" }) { http_get "/api/v1/mcp" }

    expect(response).to have_http_status(:ok)
    expect(json_body).to include("ok" => true, "account_id" => account.id)
  end

  it "401s with a bare challenge (realm + metadata document, no error code) when no token is sent" do
    http_get "/api/v1/mcp"

    expect(response).to have_http_status(:unauthorized)
    expect(json_body["error"]).to eq("invalid_token")
    expect(challenge).to eq(%(Bearer realm="mcp", resource_metadata="#{metadata_url}"))
  end

  it "401s with error=invalid_token for an expired token" do
    expired = StandardId::JwtService.encode({ sub: account.id, client_id: "svc-test", scope: "mcp", grant_type: "access_token", aud: "mcp" }, expires_at: 1.hour.ago)
    with_headers(auth_headers(expired)) { http_get "/api/v1/mcp" }

    expect(response).to have_http_status(:unauthorized)
    expect(challenge).to include(%(error="invalid_token"), %(resource_metadata="#{metadata_url}"))
  end

  it "401s an already-issued token once the account is deactivated, saying so" do
    token = bearer_jwt(account: account, scope: "mcp", extra: { aud: "mcp" })
    account.deactivate!
    with_headers(auth_headers(token)) { http_get "/api/v1/mcp" }

    expect(response).to have_http_status(:unauthorized)
    expect(json_body["error_description"]).to eq("The account is deactivated")
    expect(challenge).to include(%(error_description="The account is deactivated"), %(resource_metadata="#{metadata_url}"))
  end

  it "403s through the audience → profile-type binding when configured" do
    allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return("mcp" => %w[OrganisationProfile])
    allow(StandardId::Oauth::AudienceProfileResolver).to receive(:call).and_return(nil)
    as_service(account: account, scope: "mcp", extra: { aud: "mcp" }) { http_get "/api/v1/mcp" }

    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("insufficient_scope")
    expect(challenge).to include(%(resource_metadata="#{metadata_url}"))
  end

  it "leaves a session-less request to the auth layer rather than raising from the scope check" do
    klass = Class.new(ActionController::API) do
      include StandardId::ResourceServer
      protected_resource "mcp", scopes: %w[mcp]
    end
    controller = klass.new
    allow(controller).to receive(:current_session).and_return(nil)
    expect(controller).not_to receive(:require_scopes!)
    controller.send(:verify_protected_resource_scopes!)
  end

  it "skips the scope check when protected_resource is given no scopes" do
    klass = Class.new(ActionController::API) do
      include StandardId::ResourceServer
      protected_resource "mcp"
    end
    expect(klass._protected_resource_scopes).to eq([])
    controller = klass.new
    expect(controller).not_to receive(:require_scopes!)
    controller.send(:verify_protected_resource_scopes!)
  end

  it "401s for a garbage token" do
    with_headers(auth_headers("not-a-jwt")) { http_get "/api/v1/mcp" }

    expect(response).to have_http_status(:unauthorized)
    expect(challenge).to include(%(resource_metadata="#{metadata_url}"))
  end

  it "403s with insufficient_scope and the pointer for a token minted for another audience" do
    as_service(account: account, scope: "mcp", extra: { aud: "web" }) { http_get "/api/v1/mcp" }

    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("insufficient_scope")
    expect(json_body["error_description"]).to eq(StandardId::AudienceVerification::GENERIC_INSUFFICIENT_SCOPE_MESSAGE)
    expect(challenge).to include(%(error="insufficient_scope"), %(resource_metadata="#{metadata_url}"))
  end

  it "403s with insufficient_scope listing the required scopes when the token lacks them" do
    as_service(account: account, scope: "openid", extra: { aud: "mcp" }) { http_get "/api/v1/mcp" }

    expect(response).to have_http_status(:forbidden)
    expect(json_body["error"]).to eq("insufficient_scope")
    expect(challenge).to include(%(scope="mcp"), %(resource_metadata="#{metadata_url}"))
  end

  context "when the resource's tokens carry its absolute URL (audience: :resource) behind a public origin" do
    let(:public_metadata_url) { "https://public.example.com/.well-known/oauth-protected-resource/mcp" }

    before do
      allow(StandardId.config.oauth).to receive(:protected_resources).and_return(
        "mcp" => { path: "/mcp", audience: :resource, origin: ->(request:) { "https://public.example.com" } }
      )
    end

    it "serves a token whose aud is the resource URL on the public origin" do
      as_service(account: account, scope: "mcp", extra: { aud: "https://public.example.com/mcp" }) { http_get "/api/v1/mcp" }

      expect(response).to have_http_status(:ok)
    end

    it "403s a token carrying the bare key, and points the challenge at the public origin" do
      as_service(account: account, scope: "mcp", extra: { aud: "mcp" }) { http_get "/api/v1/mcp" }

      expect(response).to have_http_status(:forbidden)
      expect(challenge).to include(%(realm="mcp"), %(resource_metadata="#{public_metadata_url}"))
    end

    it "serves the document with the public resource URL" do
      http_get "/.well-known/oauth-protected-resource/mcp"

      expect(response).to have_http_status(:ok)
      expect(json_body["resource"]).to eq("https://public.example.com/mcp")
      expect(json_body).not_to have_key("audience")
    end
  end

  describe "class macro" do
    it "records the audience and splits scopes, and requires protected_resource to have been called" do
      klass = Class.new(ActionController::API) do
        include StandardId::ResourceServer
        protected_resource "kit", scopes: "kit kit:read"
      end
      expect(klass._protected_resource_audience).to eq("kit")
      expect(klass._protected_resource_scopes).to eq(%w[kit kit:read])
      controller = klass.new
      allow(StandardId.config.oauth).to receive(:protected_resources).and_return("kit" => { path: "/kit" })
      allow(controller).to receive(:request).and_return(instance_double(ActionDispatch::Request, base_url: "https://app.example.com"))
      expect(controller.send(:required_audiences)).to eq(%w[kit])

      bare = Class.new(ActionController::API) { include StandardId::ResourceServer }
      expect { bare.new.send(:protected_resource_audience) }.to raise_error(StandardId::ConfigurationError, /protected_resource/)
    end
  end
end
