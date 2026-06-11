require "rails_helper"

RSpec.describe StandardId::ClientGrant, type: :model do
  let(:account) { Account.create!(name: "Grantor", email: "grantor-#{SecureRandom.hex(4)}@example.com") }
  let(:client_id) { "client_#{SecureRandom.hex(4)}" }

  describe ".record!" do
    it "creates a grant and updates scope on re-approval (one row per account+client)" do
      StandardId::ClientGrant.record!(account: account, client_id: client_id, scope: "read")
      expect {
        StandardId::ClientGrant.record!(account: account, client_id: client_id, scope: "read write")
      }.not_to change(StandardId::ClientGrant, :count)

      grant = StandardId::ClientGrant.find_by(account_id: account.id, client_id: client_id)
      expect(grant.scope).to eq("read write")
    end
  end

  describe ".granted?" do
    it "is false when no grant exists" do
      expect(StandardId::ClientGrant.granted?(account: account, client_id: client_id)).to be(false)
    end

    it "is true when a grant covers the requested scope (subset)" do
      StandardId::ClientGrant.record!(account: account, client_id: client_id, scope: "read write")
      expect(
        StandardId::ClientGrant.granted?(account: account, client_id: client_id, requested_scope: "read")
      ).to be(true)
    end

    it "is false when the request asks for a scope not previously granted" do
      StandardId::ClientGrant.record!(account: account, client_id: client_id, scope: "read")
      expect(
        StandardId::ClientGrant.granted?(account: account, client_id: client_id, requested_scope: "read admin")
      ).to be(false)
    end

    it "is true when the request asks for nothing and a grant exists" do
      StandardId::ClientGrant.record!(account: account, client_id: client_id, scope: "read")
      expect(
        StandardId::ClientGrant.granted?(account: account, client_id: client_id, requested_scope: nil)
      ).to be(true)
    end

    it "is false for a nil account or blank client_id" do
      expect(StandardId::ClientGrant.granted?(account: nil, client_id: client_id)).to be(false)
      expect(StandardId::ClientGrant.granted?(account: account, client_id: "")).to be(false)
    end
  end

  describe "uniqueness" do
    it "enforces one grant per (account, client)" do
      StandardId::ClientGrant.create!(account: account, client_id: client_id)
      dup = StandardId::ClientGrant.new(account: account, client_id: client_id)
      expect(dup).not_to be_valid
    end
  end
end
