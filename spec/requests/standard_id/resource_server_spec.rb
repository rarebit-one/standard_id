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

  it "401s with an invalid_token challenge naming the metadata document when no token is sent" do
    http_get "/api/v1/mcp"

    expect(response).to have_http_status(:unauthorized)
    expect(json_body["error"]).to eq("invalid_token")
    expect(challenge).to include(%(realm="mcp"), %(error="invalid_token"), %(resource_metadata="#{metadata_url}"))
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

  describe "class macro" do
    it "records the audience and splits scopes, and requires protected_resource to have been called" do
      klass = Class.new(ActionController::API) do
        include StandardId::ResourceServer
        protected_resource "kit", scopes: "kit kit:read"
      end
      expect(klass._protected_resource_audience).to eq("kit")
      expect(klass._protected_resource_scopes).to eq(%w[kit kit:read])
      expect(klass._required_audiences).to eq(%w[kit])

      bare = Class.new(ActionController::API) { include StandardId::ResourceServer }
      expect { bare.new.send(:protected_resource_audience) }.to raise_error(StandardId::ConfigurationError, /protected_resource/)
    end
  end
end
