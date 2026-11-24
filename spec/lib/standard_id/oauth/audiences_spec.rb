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
end
