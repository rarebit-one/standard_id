require "rails_helper"

RSpec.describe StandardId::Oauth::AudienceResolver do
  let(:client) { instance_double(StandardId::ClientApplication, metadata: { "audience" => "mcp" }) }
  let(:bare_client) { instance_double(StandardId::ClientApplication, metadata: {}) }

  before do
    allow(StandardId.config.oauth).to receive(:audience_resolver).and_return(nil)
    allow(StandardId.config.oauth).to receive(:resource_audiences).and_return({})
  end

  def resolve(client: self.client, **params)
    described_class.resolve(client: client, params: ActionController::Parameters.new(params))
  end

  describe ".resolve" do
    it "prefers the explicit audience parameter" do
      expect(resolve(audience: "https://api.example.com", resource: "https://app.example.com/mcp")).to eq("https://api.example.com")
    end

    it "maps an RFC 8707 resource through resource_audiences when no audience is given" do
      allow(StandardId.config.oauth).to receive(:resource_audiences).and_return("https://app.example.com/mcp" => "mcp-api")
      expect(resolve(resource: "https://app.example.com/mcp")).to eq("mcp-api")
    end

    it "ignores a trailing slash on either side of the resource mapping" do
      allow(StandardId.config.oauth).to receive(:resource_audiences).and_return("https://app.example.com/mcp/" => "mcp-api")
      expect(resolve(resource: "https://app.example.com/mcp")).to eq("mcp-api")
      allow(StandardId.config.oauth).to receive(:resource_audiences).and_return("https://app.example.com/mcp" => "mcp-api")
      expect(resolve(resource: "https://app.example.com/mcp/")).to eq("mcp-api")
    end

    it "resolves an unmapped resource to nil rather than the client default" do
      allow(StandardId.config.oauth).to receive(:resource_audiences).and_return("https://app.example.com/mcp" => "mcp-api")
      expect(resolve(resource: "https://elsewhere.example.com")).to be_nil
    end

    it "falls back to the client's registered metadata audience" do
      expect(resolve).to eq("mcp")
    end

    it "reads a symbol-keyed metadata audience too" do
      sym_client = instance_double(StandardId::ClientApplication, metadata: { audience: "kit" })
      expect(resolve(client: sym_client)).to eq("kit")
    end

    it "is nil when nothing applies" do
      expect(resolve(client: bare_client)).to be_nil
      expect(resolve(client: nil)).to be_nil
    end

    it "treats blank audience and resource params as absent" do
      expect(resolve(audience: "", resource: " ")).to eq("mcp")
    end

    context "with a custom audience_resolver" do
      it "is final when it answers, and receives only the keywords it declares" do
        seen = nil
        allow(StandardId.config.oauth).to receive(:audience_resolver).and_return(
          ->(client:, resource:) { seen = [client, resource]; "custom" }
        )
        expect(resolve(audience: "ignored", resource: "https://r.example")).to eq("custom")
        expect(seen).to eq([client, "https://r.example"])
      end

      it "falls through to the defaults when it returns nil" do
        allow(StandardId.config.oauth).to receive(:audience_resolver).and_return(->(**) { nil })
        expect(resolve(audience: "https://api.example.com")).to eq("https://api.example.com")
        expect(resolve).to eq("mcp")
      end
    end
  end
end
