require "rails_helper"

RSpec.describe "RFC 9728 protected resource metadata", type: :request do
  before do
    allow(StandardId.config.oauth).to receive(:audience_scopes).and_return("mcp" => %w[mcp mcp:read])
    allow(StandardId.config.oauth).to receive(:audience_scope_resolver).and_return(nil)
  end

  def configure(resources)
    allow(StandardId.config.oauth).to receive(:protected_resources).and_return(resources)
  end

  context "at the origin root (standard_id_protected_resource_routes)" do
    it "serves the resource configured at the path-inserted form" do
      configure("mcp" => { path: "/mcp" })
      http_get "/.well-known/oauth-protected-resource/mcp"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("public")
      expect(json_body).to include(
        "resource" => "http://www.example.com/mcp",
        "scopes_supported" => %w[mcp mcp:read],
        "bearer_methods_supported" => %w[header]
      )
      expect(json_body["authorization_servers"]).to be_an(Array).and be_present
    end

    it "serves the default resource at the bare form" do
      configure("mcp" => { path: "/mcp" })
      http_get "/.well-known/oauth-protected-resource"
      expect(response).to have_http_status(:ok)
      expect(json_body["resource"]).to eq("http://www.example.com/mcp")
    end

    it "serves a nested path and ignores a trailing slash" do
      configure("kit" => { path: "/api/v1/kit" })
      http_get "/.well-known/oauth-protected-resource/api/v1/kit/"
      expect(response).to have_http_status(:ok)
      expect(json_body["resource"]).to eq("http://www.example.com/api/v1/kit")
    end

    it "404s for an unknown path, and at the bare form when nothing (or several, unmarked) is configured" do
      configure("mcp" => { path: "/mcp" })
      http_get "/.well-known/oauth-protected-resource/nope"
      expect(response).to have_http_status(:not_found)
      expect(json_body["error"]).to eq("not_found")

      configure({})
      http_get "/.well-known/oauth-protected-resource"
      expect(response).to have_http_status(:not_found)

      configure("mcp" => { path: "/mcp" }, "kit" => { path: "/kit" })
      http_get "/.well-known/oauth-protected-resource"
      expect(response).to have_http_status(:not_found)
    end
  end

  context "under the engine mount" do
    it "serves the same document" do
      configure("mcp" => { path: "/mcp" })
      http_get "/api/.well-known/oauth-protected-resource/mcp"
      expect(response).to have_http_status(:ok)
      expect(json_body["resource"]).to eq("http://www.example.com/mcp")
    end
  end
end
