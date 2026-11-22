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

  describe ".rekey" do
    let(:account) { Account.create!(name: "Rekey", email: "keyed-rekey@example.com") }
    let(:session) do
      StandardId::DeviceSession.create!(account: account, device_id: "d-#{SecureRandom.hex(4)}", device_agent: "x", expires_at: 1.day.from_now)
    end

    it "updates the row when it still holds the expected values" do
      expect(described_class.rekey(StandardId::Session, id: session.id, from: { lookup_hash: session.lookup_hash }, to: { lookup_hash: "new" }))
        .to be(true)
      expect(session.reload.lookup_hash).to eq("new")
    end

    it "updates nothing, and says so, when the row has changed" do
      expect(described_class.rekey(StandardId::Session, id: session.id, from: { lookup_hash: "stale" }, to: { lookup_hash: "new" }))
        .to be(false)
      expect(session.reload.lookup_hash).not_to eq("new")
    end

    it "ignores the caller's scope" do
      StandardId::Session.where(id: nil).scoping do
        expect(described_class.rekey(StandardId::Session, id: session.id, from: { lookup_hash: session.lookup_hash }, to: { lookup_hash: "new" }))
          .to be(true)
      end
    end

    it "swallows and logs errors" do
      allow(StandardId::Session).to receive(:unscoped).and_raise(ActiveRecord::ReadOnlyError, "Write query attempted while in readonly mode")
      allow(StandardId.logger).to receive(:warn)

      expect(described_class.rekey(StandardId::Session, id: session.id, from: {}, to: { lookup_hash: "new" })).to be(false)
      expect(StandardId.logger).to have_received(:warn).with(/ActiveRecord::ReadOnlyError/)
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
