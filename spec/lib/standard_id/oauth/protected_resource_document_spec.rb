require "rails_helper"

RSpec.describe StandardId::Oauth::ProtectedResourceDocument do
  let(:origin) { "https://app.example.com" }

  before do
    allow(StandardId.config.oauth).to receive(:audience_scopes).and_return({})
    allow(StandardId.config.oauth).to receive(:audience_scope_resolver).and_return(nil)
    allow(StandardId.config).to receive(:issuer).and_return(nil)
  end

  def configure(resources)
    allow(StandardId.config.oauth).to receive(:protected_resources).and_return(resources)
  end

  describe ".audience_for_path / .default_audience" do
    it "matches a path with or without a trailing slash and ignores unknown paths" do
      configure("mcp" => { path: "/mcp" }, "kit" => { path: "/kit/" })
      expect(described_class.audience_for_path("/mcp/")).to eq("mcp")
      expect(described_class.audience_for_path("/kit")).to eq("kit")
      expect(described_class.audience_for_path("/nope")).to be_nil
      expect(described_class.audience_for_path("")).to be_nil
    end

    it "defaults to the only resource, else the one marked root, else nil" do
      configure("mcp" => { path: "/mcp" })
      expect(described_class.default_audience).to eq("mcp")

      configure("mcp" => { path: "/mcp" }, "kit" => { path: "/kit", root: true })
      expect(described_class.default_audience).to eq("kit")

      configure("mcp" => { path: "/mcp" }, "kit" => { path: "/kit" })
      expect(described_class.default_audience).to be_nil

      configure({})
      expect(described_class.default_audience).to be_nil
    end
  end

  describe ".resource_url / .metadata_url" do
    it "builds both off the origin for a relative path" do
      configure("mcp" => { path: "mcp/" })
      expect(described_class.resource_url(audience: "mcp", origin: origin)).to eq("https://app.example.com/mcp")
      expect(described_class.metadata_url(audience: "mcp", origin: origin)).to eq("https://app.example.com/.well-known/oauth-protected-resource/mcp")
    end

    it "keeps an absolute resource URL and still serves its metadata from this origin" do
      configure("mcp" => { path: "https://mcp.example.net/v1/" })
      expect(described_class.resource_url(audience: "mcp", origin: origin)).to eq("https://mcp.example.net/v1")
      expect(described_class.metadata_url(audience: "mcp", origin: origin)).to eq("https://app.example.com/.well-known/oauth-protected-resource/v1")
    end

    it "raises a ConfigurationError for an entry without a path" do
      configure("mcp" => { scopes_supported: %w[mcp] })
      expect { described_class.resource_url(audience: "mcp", origin: origin) }.to raise_error(StandardId::ConfigurationError, /path/)
    end
  end

  describe ".build" do
    it "emits the RFC 9728 members with defaults from the issuer and audience_scopes" do
      allow(StandardId.config).to receive(:issuer).and_return("https://id.example.com")
      allow(StandardId.config.oauth).to receive(:audience_scopes).and_return("mcp" => %w[mcp mcp:read])
      configure("mcp" => { path: "/mcp" })

      expect(described_class.build(audience: "mcp", origin: origin)).to eq(
        resource: "https://app.example.com/mcp",
        authorization_servers: ["https://id.example.com"],
        bearer_methods_supported: %w[header],
        scopes_supported: %w[mcp mcp:read]
      )
    end

    it "falls back to the origin as the authorization server and omits scopes_supported when none are known" do
      configure("mcp" => { path: "/mcp" })
      doc = described_class.build(audience: "mcp", origin: origin)
      expect(doc[:authorization_servers]).to eq([origin])
      expect(doc).not_to have_key(:scopes_supported)
    end

    it "lets the entry override, add (including via callables) and remove members" do
      allow(StandardId.config.oauth).to receive(:audience_scopes).and_return("mcp" => %w[mcp mcp:read])
      configure("mcp" => {
        path: "/mcp",
        scopes_supported: %w[mcp],
        resource_name: ->(ctx) { "MCP at #{ctx[:origin]} for #{ctx[:audience]}" },
        bearer_methods_supported: nil
      })

      doc = described_class.build(audience: "mcp", origin: origin)
      expect(doc[:scopes_supported]).to eq(%w[mcp])
      expect(doc[:resource_name]).to eq("MCP at https://app.example.com for mcp")
      expect(doc).not_to have_key(:bearer_methods_supported)
    end

    it "raises for an unconfigured audience" do
      configure({})
      expect { described_class.build(audience: "mcp", origin: origin) }.to raise_error(StandardId::ConfigurationError, /no entry/)
    end
  end

  describe ".challenge" do
    before { configure("mcp" => { path: "/mcp" }) }

    it "names the realm, error, description, scope and the metadata document" do
      value = described_class.challenge(audience: "mcp", origin: origin, error: "insufficient_scope", error_description: "Needs mcp", scope: %w[mcp mcp:read])
      expect(value).to eq(%(Bearer realm="mcp", error="insufficient_scope", error_description="Needs mcp", scope="mcp mcp:read", resource_metadata="https://app.example.com/.well-known/oauth-protected-resource/mcp"))
    end

    it "drops a description that would break the quoted-string, rather than emit it broken" do
      value = described_class.challenge(audience: "mcp", origin: origin, error_description: %(bad "quote"))
      expect(value).to eq(%(Bearer realm="mcp", error="invalid_token", resource_metadata="https://app.example.com/.well-known/oauth-protected-resource/mcp"))
    end
  end
end
