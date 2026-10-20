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
      expect { described_class.metadata_url(audience: "mcp", origin: origin) }.to raise_error(StandardId::ConfigurationError, /path/)
    end

    it "raises a ConfigurationError for an unconfigured audience rather than naming a bare URL" do
      configure("mcp" => { path: "/mcp" })
      expect { described_class.metadata_url(audience: "kit", origin: origin) }.to raise_error(StandardId::ConfigurationError, /no entry/)
      expect { described_class.challenge(audience: "kit", origin: origin) }.to raise_error(StandardId::ConfigurationError, /no entry/)
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

    it "never lets the entry override the computed resource (RFC 9728 §3.3)" do
      configure("mcp" => { path: "/mcp", resource: "https://attacker.example" })
      expect(described_class.build(audience: "mcp", origin: origin)[:resource]).to eq("https://app.example.com/mcp")
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

    it "omits the error code when asked to (the no-credential form of RFC 6750 §3.1)" do
      value = described_class.challenge(audience: "mcp", origin: origin, error: nil)
      expect(value).to eq(%(Bearer realm="mcp", resource_metadata="https://app.example.com/.well-known/oauth-protected-resource/mcp"))
    end

    it "serves the metadata of a resource on another origin from this origin" do
      configure("mcp" => { path: "https://mcp.example.net/v1" })
      value = described_class.challenge(audience: "mcp", origin: origin, error: nil)
      expect(value).to include(%(resource_metadata="https://app.example.com/.well-known/oauth-protected-resource/v1"))
    end

    it "drops a description that would break the quoted-string, rather than emit it broken" do
      value = described_class.challenge(audience: "mcp", origin: origin, error_description: %(bad "quote"))
      expect(value).to eq(%(Bearer realm="mcp", error="invalid_token", resource_metadata="https://app.example.com/.well-known/oauth-protected-resource/mcp"))
    end
  end

  describe "origin: and audience: members" do
    let(:request) { instance_double(ActionDispatch::Request, base_url: "http://internal:3000") }

    it "builds on the request origin by default and on the entry's origin callable when it answers" do
      configure("mcp" => { path: "/mcp" })
      expect(described_class.origin_for("mcp", request: request)).to eq("http://internal:3000")

      configure("mcp" => { path: "/mcp", origin: ->(request:) { "https://public.example.com/" } })
      expect(described_class.origin_for("mcp", request: request)).to eq("https://public.example.com")

      configure("mcp" => { path: "/mcp", origin: -> { nil } })
      expect(described_class.origin_for("mcp", request: request)).to eq("http://internal:3000")
    end

    it "answers the key as the token audience by default, the resource URL for :resource, or the named String" do
      configure("mcp" => { path: "/mcp" })
      expect(described_class.token_audience(audience: "mcp", origin: origin)).to eq("mcp")
      expect(described_class.token_audience(audience: "unconfigured", origin: origin)).to eq("unconfigured")

      configure("mcp" => { path: "/mcp/", audience: :resource })
      expect(described_class.token_audience(audience: "mcp", origin: origin)).to eq("https://app.example.com/mcp")

      configure("mcp" => { path: "/mcp", audience: "https://fixed.example.com/mcp" })
      expect(described_class.token_audience(audience: "mcp", origin: origin)).to eq("https://fixed.example.com/mcp")

      configure("mcp" => { path: "/mcp", audience: 42 })
      expect { described_class.token_audience(audience: "mcp", origin: origin) }.to raise_error(StandardId::ConfigurationError, /:resource or a String/)
    end

    it "keeps both members out of the document" do
      configure("mcp" => { path: "/mcp", audience: :resource, origin: ->(request:) { "https://public.example.com" } })
      doc = described_class.build(audience: "mcp", origin: "https://public.example.com")
      expect(doc.keys).not_to include(:audience, :origin)
      expect(doc[:resource]).to eq("https://public.example.com/mcp")
    end
  end
end
