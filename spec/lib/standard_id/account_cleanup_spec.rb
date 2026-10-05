require "rails_helper"

RSpec.describe StandardId::AccountCleanup do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:account) do
    Account.create!(name: "Kept", email: "kept-#{SecureRandom.hex(4)}@example.com").tap do |account|
      StandardId::EmailIdentifier.create!(account: account, value: account.email, provider: "google")
    end
  end

  before { allow(StandardId).to receive(:cache_store).and_return(cache) }

  def sign_in(account, agent)
    StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1", user_agent: agent, expires_at: 1.hour.from_now)
  end

  # A refused request keeps its new account because `adopter` is signed in
  # to it; the adopter then fails and revokes its session.
  def keep_for_then_fail(adopter)
    expect(described_class.destroy_newly_created!(account)).to be(false)
    adopter.revoke!(reason: "social_sign_in_rejected")
  end

  describe ".reclaim_for_failed_adopter!" do
    it "removes an account that was kept only for the failing sign-in" do
      adopter = sign_in(account, "B")
      keep_for_then_fail(adopter)

      expect(described_class.reclaim_for_failed_adopter!(account, sessions: [adopter])).to be(true)
      expect(Account.exists?(account.id)).to be(false)
      expect(StandardId::Identifier.where(account_id: account.id)).to be_empty
      expect(cache.read("standard_id:account_cleanup:kept_for:Account:#{account.id}")).to be_nil
    end

    it "keeps an account that was never kept by a refused request" do
      adopter = sign_in(account, "B")
      adopter.revoke!(reason: "social_sign_in_rejected")

      expect(described_class.reclaim_for_failed_adopter!(account, sessions: [adopter])).to be(false)
      expect(Account.exists?(account.id)).to be(true)
    end

    it "keeps the account when the failing sign-in is not one it was kept for" do
      adopter = sign_in(account, "B")
      keep_for_then_fail(adopter)
      later = sign_in(account, "C")
      later.revoke!(reason: "social_sign_in_rejected")

      expect(described_class.reclaim_for_failed_adopter!(account, sessions: [later])).to be(false)
      expect(Account.exists?(account.id)).to be(true)
    end

    it "keeps the account, now for the remaining adopter, while another sign-in still uses it" do
      adopter = sign_in(account, "B")
      other = sign_in(account, "C")
      keep_for_then_fail(adopter)

      expect(described_class.reclaim_for_failed_adopter!(account, sessions: [adopter])).to be(false)
      expect(Account.exists?(account.id)).to be(true)

      other.revoke!(reason: "social_sign_in_rejected")
      expect(described_class.reclaim_for_failed_adopter!(account, sessions: [other])).to be(true)
      expect(Account.exists?(account.id)).to be(false)
    end

    it "matches a kept-for refresh token as well as a session" do
      token = StandardId::RefreshToken.create!(account_id: account.id, token_digest: SecureRandom.hex(16), expires_at: 1.hour.from_now)
      expect(described_class.destroy_newly_created!(account)).to be(false)
      token.revoke!

      expect(described_class.reclaim_for_failed_adopter!(account, refresh_tokens: [token])).to be(true)
      expect(Account.exists?(account.id)).to be(false)
    end

    it "keeps the account when the cache store does not remember (null store)" do
      allow(StandardId).to receive(:cache_store).and_return(ActiveSupport::Cache::NullStore.new)
      adopter = sign_in(account, "B")
      keep_for_then_fail(adopter)

      expect(described_class.reclaim_for_failed_adopter!(account, sessions: [adopter])).to be(false)
      expect(Account.exists?(account.id)).to be(true)
    end

    it "is a no-op without issued credentials or a persisted account" do
      expect(described_class.reclaim_for_failed_adopter!(account)).to be(false)
      expect(described_class.reclaim_for_failed_adopter!(nil, sessions: [])).to be(false)
      expect(Account.exists?(account.id)).to be(true)
    end
  end
end
