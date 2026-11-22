require "rails_helper"

RSpec.describe StandardId::KeyedDigest do
  let(:current) { Rails.configuration.secret_key_base }

  describe ".secrets" do
    it "is only the current secret by default" do
      expect(described_class.secrets).to eq([current])
    end

    it "puts the current secret first, then the previous ones in order" do
      StandardId.config.previous_secret_key_bases = %w[older oldest]

      expect(described_class.secrets).to eq([current, "older", "oldest"])
    end

    it "drops blank entries and duplicates" do
      StandardId.config.previous_secret_key_bases = ["", nil, "older", current, "older"]

      expect(described_class.secrets).to eq([current, "older"])
    end
  end

  describe ".previous_secrets" do
    it "is empty by default" do
      expect(described_class.previous_secrets).to eq([])
    end

    it "is the configured previous secrets as strings, blanks dropped" do
      StandardId.config.previous_secret_key_bases = ["", nil, "older", :oldest]

      expect(described_class.previous_secrets).to eq(%w[older oldest])
    end
  end

  describe ".hmac_hexdigest" do
    it "is HMAC-SHA256 under the current secret by default" do
      expect(described_class.hmac_hexdigest("data")).to eq(OpenSSL::HMAC.hexdigest("SHA256", current, "data"))
    end

    it "uses the given secret" do
      expect(described_class.hmac_hexdigest("data", secret: "other")).to eq(OpenSSL::HMAC.hexdigest("SHA256", "other", "data"))
    end
  end

  describe ".candidates" do
    it "yields each accepted secret, current first" do
      StandardId.config.previous_secret_key_bases = ["older"]

      expect(described_class.candidates { |secret| "#{secret}!" }).to eq(["#{current}!", "older!"])
    end
  end

  describe ".secure_match?" do
    it "is true when any candidate matches" do
      expect(described_class.secure_match?("b", %w[a b c])).to be(true)
    end

    it "is false when none does, or the stored value is blank" do
      expect(described_class.secure_match?("d", %w[a b c])).to be(false)
      expect(described_class.secure_match?(nil, %w[a])).to be(false)
      expect(described_class.secure_match?("", [""])).to be(false)
    end

    it "compares against every candidate, not just up to the first match" do
      allow(ActiveSupport::SecurityUtils).to receive(:secure_compare).and_call_original

      described_class.secure_match?("a", %w[a b c])

      expect(ActiveSupport::SecurityUtils).to have_received(:secure_compare).exactly(3).times
    end
  end
end
