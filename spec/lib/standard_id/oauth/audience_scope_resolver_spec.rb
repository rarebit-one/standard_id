require "rails_helper"

RSpec.describe StandardId::Oauth::AudienceScopeResolver do
  before do
    allow(StandardId.config.oauth).to receive(:audience_scopes).and_return({})
    allow(StandardId.config.oauth).to receive(:audience_scope_resolver).and_return(nil)
  end

  def configure_scopes(mapping)
    allow(StandardId.config.oauth).to receive(:audience_scopes).and_return(mapping)
  end

  describe ".scopes_for" do
    it "returns [] when no mapping is configured" do
      expect(described_class.scopes_for(audience: "harness")).to eq([])
    end

    it "returns [] for a blank audience" do
      configure_scopes("harness" => %w[mcp])
      expect(described_class.scopes_for(audience: nil)).to eq([])
      expect(described_class.scopes_for(audience: "")).to eq([])
    end

    it "returns the Array mapping for the audience" do
      configure_scopes("harness" => %w[mcp mcp:read mcp:eval:run])
      expect(described_class.scopes_for(audience: "harness")).to eq(%w[mcp mcp:read mcp:eval:run])
    end

    it "splits a space-delimited String mapping into an Array" do
      configure_scopes("companion_kit" => "mcp mcp:read")
      expect(described_class.scopes_for(audience: "companion_kit")).to eq(%w[mcp mcp:read])
    end

    it "treats symbol keys equivalently to string keys" do
      configure_scopes(harness: %w[mcp])
      expect(described_class.scopes_for(audience: "harness")).to eq(%w[mcp])
    end

    it "de-duplicates and strips blanks" do
      configure_scopes("harness" => ["mcp", "mcp", " mcp:read ", ""])
      expect(described_class.scopes_for(audience: "harness")).to eq(%w[mcp mcp:read])
    end

    context "with a resolver callable" do
      it "uses the resolver's value over the static map when non-nil" do
        configure_scopes("harness" => %w[mcp])
        allow(StandardId.config.oauth).to receive(:audience_scope_resolver).and_return(
          ->(audience:, client:, configured_scopes:) { configured_scopes + %w[mcp:admin] }
        )
        expect(described_class.scopes_for(audience: "harness", client: double)).to eq(%w[mcp mcp:admin])
      end

      it "falls back to the static map when the resolver returns nil" do
        configure_scopes("harness" => %w[mcp mcp:read])
        allow(StandardId.config.oauth).to receive(:audience_scope_resolver).and_return(
          ->(**) { nil }
        )
        expect(described_class.scopes_for(audience: "harness")).to eq(%w[mcp mcp:read])
      end

      it "filters the callable's arguments by arity (accepts a bare audience:)" do
        allow(StandardId.config.oauth).to receive(:audience_scope_resolver).and_return(
          ->(audience:) { audience == "harness" ? %w[mcp] : [] }
        )
        expect(described_class.scopes_for(audience: "harness")).to eq(%w[mcp])
      end

      it "normalizes a String returned by the resolver" do
        allow(StandardId.config.oauth).to receive(:audience_scope_resolver).and_return(
          ->(**) { "mcp mcp:read mcp" }
        )
        expect(described_class.scopes_for(audience: "harness")).to eq(%w[mcp mcp:read])
      end
    end
  end

  describe ".configured_for?" do
    it "is false when no vocabulary exists" do
      expect(described_class.configured_for?("harness")).to be(false)
    end

    it "is true when a non-empty vocabulary exists" do
      configure_scopes("harness" => %w[mcp])
      expect(described_class.configured_for?("harness")).to be(true)
    end
  end

  describe ".permits?" do
    it "permits any scope for an unconfigured audience (fail open)" do
      expect(described_class.permits?(scope: "anything", audience: "harness")).to be(true)
    end

    it "permits a scope inside the vocabulary" do
      configure_scopes("harness" => %w[mcp mcp:read])
      expect(described_class.permits?(scope: "mcp:read", audience: "harness")).to be(true)
    end

    it "denies a scope outside the vocabulary" do
      configure_scopes("harness" => %w[mcp mcp:read])
      expect(described_class.permits?(scope: "mcp:admin", audience: "harness")).to be(false)
    end

    it "denies a blank scope" do
      configure_scopes("harness" => %w[mcp])
      expect(described_class.permits?(scope: "", audience: "harness")).to be(false)
    end
  end

  describe ".filter" do
    it "passes requested scopes through unchanged for an unconfigured audience" do
      expect(described_class.filter(requested: %w[mcp mcp:admin], audience: "harness")).to eq(%w[mcp mcp:admin])
    end

    it "narrows requested scopes to the vocabulary, preserving request order" do
      configure_scopes("companion_kit" => %w[mcp mcp:read])
      expect(
        described_class.filter(requested: %w[mcp:read openid mcp], audience: "companion_kit")
      ).to eq(%w[mcp:read mcp])
    end

    it "accepts a space-delimited String of requested scopes" do
      configure_scopes("companion_kit" => %w[mcp mcp:read])
      expect(described_class.filter(requested: "mcp mcp:admin", audience: "companion_kit")).to eq(%w[mcp])
    end
  end

  describe ".disallowed" do
    it "is empty for an unconfigured audience" do
      expect(described_class.disallowed(requested: %w[mcp mcp:admin], audience: "harness")).to eq([])
    end

    it "returns the requested scopes outside the vocabulary" do
      configure_scopes("companion_kit" => %w[mcp mcp:read])
      expect(
        described_class.disallowed(requested: %w[mcp mcp:admin openid], audience: "companion_kit")
      ).to eq(%w[mcp:admin openid])
    end
  end

  describe ".assert!" do
    it "returns the normalized requested scopes when all are permitted" do
      configure_scopes("harness" => %w[mcp mcp:read])
      expect(described_class.assert!(requested: %w[mcp mcp:read], audience: "harness")).to eq(%w[mcp mcp:read])
    end

    it "is a pass-through for an unconfigured audience (fail open)" do
      expect(described_class.assert!(requested: "mcp mcp:admin", audience: "harness")).to eq(%w[mcp mcp:admin])
    end

    it "raises InvalidScopeError naming the offending scopes when one is out of vocabulary" do
      configure_scopes("companion_kit" => %w[mcp mcp:read])
      expect {
        described_class.assert!(requested: %w[mcp mcp:admin], audience: "companion_kit")
      }.to raise_error(StandardId::InvalidScopeError, /mcp:admin/)
    end

    it "raises an error whose oauth_error_code is :invalid_scope" do
      configure_scopes("companion_kit" => %w[mcp])
      begin
        described_class.assert!(requested: %w[mcp:admin], audience: "companion_kit")
      rescue StandardId::InvalidScopeError => e
        expect(e.oauth_error_code).to eq(:invalid_scope)
      end
    end
  end
end
