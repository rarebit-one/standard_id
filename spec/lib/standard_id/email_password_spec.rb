require "rails_helper"

RSpec.describe StandardId::EmailPassword do
  include ActiveSupport::Testing::TimeHelpers
  include RequestSpecHelpers

  before { StandardId.config.email_password.enabled = true }

  describe ".normalize_email / .valid_email?" do
    it "strips and downcases" do
      expect(described_class.normalize_email("  Mixed.Case@Example.COM ")).to eq("mixed.case@example.com")
      expect(described_class.normalize_email(nil)).to eq("")
    end

    it "accepts a plausible address only" do
      expect(described_class.valid_email?("someone@example.com")).to be(true)
      expect(described_class.valid_email?("someone")).to be(false)
      expect(described_class.valid_email?("")).to be(false)
    end
  end

  describe ".client_key" do
    let(:request) { ActionDispatch::TestRequest.create("REMOTE_ADDR" => "203.0.113.9") }

    it "defaults to the remote IP" do
      expect(described_class.client_key(request)).to eq("203.0.113.9")
    end

    it "uses c.email_password.client_key when set" do
      StandardId.config.email_password.client_key = ->(request:) { "net:#{request.remote_ip}" }

      expect(described_class.client_key(request)).to eq("net:203.0.113.9")
    end
  end

  describe ".discard_pending_credentials!" do
    let(:email) { "pending@example.com" }
    let!(:account) { create_account_with_password(email: email, password: "Attack3r-pass!", name: "Pending") }
    let!(:identifier) { StandardId::EmailIdentifier.find_by!(value: email).tap { |i| i.update_columns(verified_at: nil) } }

    it "drops the password of an unverified identifier and revokes what was issued before" do
      earlier = StandardId::RefreshToken.create!(account: account, token_digest: Digest::SHA256.hexdigest("earlier"), expires_at: 30.days.from_now)
      earlier.update_columns(created_at: 1.hour.ago)
      social_login = StandardId::RefreshToken.create!(account: account, token_digest: Digest::SHA256.hexdigest("social"), expires_at: 30.days.from_now)

      expect(described_class.discard_pending_credentials!(account, issued_before: 1.minute.ago)).to eq(1)

      expect(StandardId::PasswordCredential.where(login: email)).to be_empty
      expect(identifier.reload).to be_present
      expect(earlier.reload.revoked_at).to be_present
      expect(social_login.reload.revoked_at).to be_nil
    end

    it "keeps the password of a verified identifier and revokes nothing" do
      identifier.update!(verified_at: Time.current)
      token = StandardId::RefreshToken.create!(account: account, token_digest: Digest::SHA256.hexdigest("kept"), expires_at: 30.days.from_now)

      expect(described_class.discard_pending_credentials!(account)).to eq(0)

      expect(StandardId::PasswordCredential.where(login: email)).to exist
      expect(token.reload.revoked_at).to be_nil
    end

    it "is a no-op for nil" do
      expect(described_class.discard_pending_credentials!(nil)).to eq(0)
    end
  end

  describe StandardId::EmailPassword::DailyLimit do
    before { StandardId.config.cache_store = ActiveSupport::Cache::MemoryStore.new }

    it "admits events up to the cap, then refuses, for 24 hours from the first" do
      StandardId.config.rate_limits.email_password_codes_per_day = 2

      expect(2.times.map { described_class.consume!(:code_issued, "a@example.com") }).to eq([true, true])
      expect(described_class.consume!(:code_issued, "A@Example.com ")).to be(false)

      travel(described_class::WINDOW + 1.second) do
        expect(described_class.consume!(:code_issued, "a@example.com")).to be(true)
      end
    end

    it "counts each scope separately" do
      StandardId.config.rate_limits.email_password_reset_requests_per_network_per_day = 1
      described_class.record!(:reset_requested_network, "a@example.com", scope: "net-a")

      expect(described_class.exceeded?(:reset_requested_network, "a@example.com", scope: "net-a")).to be(true)
      expect(described_class.exceeded?(:reset_requested_network, "a@example.com", scope: "net-b")).to be(false)
    end

    it "keys on a digest, never the address" do
      expect(described_class.key(:code_issued, "a@example.com")).not_to include("example.com")
    end

    it "rejects an unknown kind" do
      expect { described_class.key(:nope, "a@example.com") }.to raise_error(KeyError)
    end

    it "is effectively off on a store that cannot count" do
      StandardId.config.cache_store = ActiveSupport::Cache::NullStore.new
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::NullStore.new)
      StandardId.config.rate_limits.email_password_codes_per_day = 1

      expect(3.times.map { described_class.consume!(:code_issued, "a@example.com") }).to all(be(true))
    end
  end
end
