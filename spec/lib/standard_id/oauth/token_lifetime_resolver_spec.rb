require "rails_helper"

RSpec.describe StandardId::Oauth::TokenLifetimeResolver do
  describe ".access_token_for" do
    it "returns the default when no override is configured" do
      result = described_class.access_token_for(:password)
      expect(result).to eq(1.hour)
    end

    it "clamps values exceeding the maximum (24 hours)" do
      allow(StandardId.config.oauth).to receive(:default_token_lifetime).and_return(48.hours)

      result = described_class.access_token_for(:password)
      expect(result.to_i).to eq(24.hours.to_i)
    end
  end

  describe ".refresh_token_lifetime" do
    it "returns the default when not configured" do
      result = described_class.refresh_token_lifetime
      expect(result).to eq(30.days)
    end

    it "clamps values exceeding the maximum (90 days)" do
      allow(StandardId.config.oauth).to receive(:refresh_token_lifetime).and_return(365.days)

      result = described_class.refresh_token_lifetime
      expect(result.to_i).to eq(90.days.to_i)
    end
  end
end
