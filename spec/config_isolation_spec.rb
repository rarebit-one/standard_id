require "rails_helper"

# Guards spec/support/config_isolation.rb — the hook that stops any example
# from leaking a mutation of the process-global StandardId.config into the
# rest of the suite.
RSpec.describe "StandardId global config isolation" do
  # Captured at load time, before any example has had a chance to mutate.
  BASELINE_USE_INERTIA = StandardId.config.use_inertia
  BASELINE_ISSUER = StandardId.config.issuer

  describe "per-example restoration" do
    # Both examples assert the baseline first and mutate after, so whichever
    # order RSpec picks, the second one fails if the first one leaked.
    it "does not see mutations from a sibling example (A)" do
      expect(StandardId.config.use_inertia).to eq(BASELINE_USE_INERTIA)
      expect(StandardId.config[:social].resolver).to be_nil

      StandardId.configure { |c| c.use_inertia = true }
      StandardId.register(:social, -> { { google_client_id: "leaked-a" } })
    end

    it "does not see mutations from a sibling example (B)" do
      expect(StandardId.config.use_inertia).to eq(BASELINE_USE_INERTIA)
      expect(StandardId.config[:social].resolver).to be_nil

      StandardId.configure { |c| c.use_inertia = true }
      StandardId.register(:social, -> { { google_client_id: "leaked-b" } })
    end
  end

  describe StandardIdConfigIsolation do
    it "restores scalar values changed after the snapshot" do
      saved = described_class.snapshot
      StandardId.configure { |c| c.issuer = "https://leaked.example.com" }
      expect(StandardId.config.issuer).to eq("https://leaked.example.com")

      described_class.restore(saved)

      expect(StandardId.config.issuer).to eq(BASELINE_ISSUER)
    end

    it "restores a scope resolver registered after the snapshot" do
      saved = described_class.snapshot
      StandardId.register(:social, -> { { google_client_id: "leaked" } })
      expect(StandardId.config.google_client_id).to eq("leaked")

      described_class.restore(saved)

      expect(StandardId.config[:social].resolver).to be_nil
    end

    it "restores scope objects in place so held references stay live" do
      scope = StandardId.config[:base]
      saved = described_class.snapshot
      StandardId.configure { |c| c.issuer = "https://leaked.example.com" }

      described_class.restore(saved)

      expect(StandardId.config[:base]).to be(scope)
      expect(scope[:issuer]).to eq(BASELINE_ISSUER)
    end
  end
end
