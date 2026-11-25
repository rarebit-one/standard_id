require "rails_helper"

RSpec.describe StandardId::Oauth::Audiences do
  let(:oauth) { StandardId.config.oauth }

  before { allow(oauth).to receive(:allowed_audiences).and_return(%w[web api]) }

  context "when neither split setting is set (default)" do
    it "uses allowed_audiences for both sides" do
      expect(oauth.mintable_audiences).to be_nil
      expect(oauth.accepted_audiences).to be_nil
      expect(described_class.mintable).to eq(%w[web api])
      expect(described_class.accepted).to eq(%w[web api])
    end
  end

  context "when mintable_audiences is set" do
    before { allow(oauth).to receive(:mintable_audiences).and_return(%w[web harness]) }

    it "wins for minting and leaves accepting on allowed_audiences" do
      expect(described_class.mintable).to eq(%w[web harness])
      expect(described_class.accepted).to eq(%w[web api])
    end
  end

  context "when accepted_audiences is set" do
    before { allow(oauth).to receive(:accepted_audiences).and_return(%w[web]) }

    it "wins for accepting and leaves minting on allowed_audiences" do
      expect(described_class.mintable).to eq(%w[web api])
      expect(described_class.accepted).to eq(%w[web])
    end
  end

  context "when a split setting is set to an empty list" do
    before { allow(oauth).to receive(:accepted_audiences).and_return([]) }

    it "takes the explicit empty list rather than falling back" do
      expect(described_class.accepted).to eq([])
    end
  end

  it "stringifies symbol entries" do
    allow(oauth).to receive(:mintable_audiences).and_return(%i[harness])

    expect(described_class.mintable).to eq(%w[harness])
  end

  describe ".endpoint" do
    it "is empty for every endpoint by default" do
      expect(described_class::ENDPOINTS.map { |name| described_class.endpoint(name) }).to all(eq([]))
      expect(described_class.unrestricted_endpoints).to eq(described_class::ENDPOINTS)
    end

    it "reads symbol and string keys and stringifies the audiences" do
      allow(oauth).to receive(:endpoint_audiences).and_return(userinfo: %i[companion_kit], "sessions" => "admin_kit")

      expect(described_class.endpoint(:userinfo)).to eq(%w[companion_kit])
      expect(described_class.endpoint(:sessions)).to eq(%w[admin_kit])
      expect(described_class.unrestricted_endpoints).to eq(%i[step_up])
    end
  end

  describe ".validate_endpoint_audiences!" do
    it "accepts the known endpoints" do
      allow(oauth).to receive(:endpoint_audiences).and_return(userinfo: %w[a], "sessions" => %w[a], step_up: %w[a])

      expect { described_class.validate_endpoint_audiences! }.not_to raise_error
    end

    it "refuses an unknown key, which would leave its endpoint open" do
      allow(oauth).to receive(:endpoint_audiences).and_return(session: %w[a])

      expect { described_class.validate_endpoint_audiences! }
        .to raise_error(StandardId::ConfigurationError, /unknown endpoint\(s\) session/)
    end
  end
end
