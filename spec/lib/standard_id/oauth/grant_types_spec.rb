require "rails_helper"

RSpec.describe StandardId::Oauth::GrantTypes do
  def stub_disabled(value)
    allow(StandardId.config.oauth).to receive(:disabled_grant_types).and_return(value)
  end

  describe ".disabled" do
    it "is empty by default" do
      expect(described_class.disabled).to eq([])
    end

    it "treats nil as empty" do
      stub_disabled(nil)
      expect(described_class.disabled).to eq([])
    end

    it "normalises symbols to strings and keeps order" do
      stub_disabled([:password, "client_credentials"])
      expect(described_class.disabled).to eq(%w[password client_credentials])
    end
  end

  describe ".disabled?" do
    before { stub_disabled(%w[password]) }

    it "matches a string or symbol name" do
      expect(described_class.disabled?("password")).to be(true)
      expect(described_class.disabled?(:password)).to be(true)
    end

    it "is false for other grants and for nil" do
      expect(described_class.disabled?("refresh_token")).to be(false)
      expect(described_class.disabled?(nil)).to be(false)
    end
  end
end
