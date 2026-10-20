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
    it "prefers the client's registered default over the audience parameter" do
      expect(resolve(audience: "https://api.example.com", resource: "https://app.example.com/mcp")).to eq("mcp")
    end

    it "takes the explicit audience parameter for a client with no registered default" do
      expect(resolve(client: bare_client, audience: "https://api.example.com", resource: "https://app.example.com/mcp")).to eq("https://api.example.com")
    end

    it "maps an RFC 8707 resource through resource_audiences for a client with no registered default" do
      allow(StandardId.config.oauth).to receive(:resource_audiences).and_return("https://app.example.com/mcp" => "mcp-api")
      expect(resolve(client: bare_client, resource: "https://app.example.com/mcp")).to eq("mcp-api")
    end

    it "ignores a trailing slash on either side of the resource mapping" do
      allow(StandardId.config.oauth).to receive(:resource_audiences).and_return("https://app.example.com/mcp/" => "mcp-api")
      expect(resolve(client: bare_client, resource: "https://app.example.com/mcp")).to eq("mcp-api")
      allow(StandardId.config.oauth).to receive(:resource_audiences).and_return("https://app.example.com/mcp" => "mcp-api")
      expect(resolve(client: bare_client, resource: "https://app.example.com/mcp/")).to eq("mcp-api")
    end

    it "refuses an unmapped resource with invalid_target once a mapping is configured" do
      allow(StandardId.config.oauth).to receive(:resource_audiences).and_return("https://app.example.com/mcp" => "mcp-api")
      expect { resolve(client: bare_client, resource: "https://elsewhere.example.com") }.to raise_error(StandardId::InvalidTargetError) { |e|
        expect(e.oauth_error_code).to eq(:invalid_target)
      }
    end

    it "ignores the resource parameter when no mapping is configured, so the client default still applies" do
      expect(resolve(resource: "https://app.example.com/mcp")).to eq("mcp")
      expect(resolve(client: bare_client, resource: "https://app.example.com/mcp")).to be_nil
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
        expect(resolve(client: bare_client, audience: "https://api.example.com")).to eq("https://api.example.com")
        expect(resolve).to eq("mcp")
      end

      it "treats a blank answer as 'no audience' rather than falling through" do
        allow(StandardId.config.oauth).to receive(:audience_resolver).and_return(->(**) { "" })
        expect(resolve(client: bare_client, audience: "https://api.example.com")).to be_nil
      end

      it "accepts a Symbol answer" do
        allow(StandardId.config.oauth).to receive(:audience_resolver).and_return(->(**) { :kit })
        expect(resolve).to eq("kit")
      end

      it "raises ConfigurationError on a non-string answer instead of stringifying it" do
        allow(StandardId.config.oauth).to receive(:audience_resolver).and_return(->(**) { %w[a b] })
        expect { resolve }.to raise_error(StandardId::ConfigurationError, /audience_resolver/)
      end
    end
  end
end
