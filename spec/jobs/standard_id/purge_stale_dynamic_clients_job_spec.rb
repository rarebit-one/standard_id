require "rails_helper"

RSpec.describe StandardId::PurgeStaleDynamicClientsJob, type: :job do
  let(:owner) { Account.create!(name: "DCR Owner", email: "dcr-purge-#{SecureRandom.hex(4)}@example.com") }

  before do
    allow(StandardId.config.oauth).to receive(:dynamic_registration_owner).and_return(-> { owner })
  end

  def register!(created_at: 8.days.ago)
    client = StandardId::Oauth::ClientRegistration.call(redirect_uris: ["https://app.example.com/cb"]).client
    client.update_columns(created_at: created_at)
    client
  end

  it "deletes never-authorized clients past the grace window and deregistered ones, and keeps everything else" do
    stale = register!
    fresh = register!(created_at: 1.hour.ago)
    granted = register!
    StandardId::ClientGrant.create!(account: owner, client_id: granted.client_id, scope: "mcp")
    in_flight = register!
    StandardId::AuthorizationCode.issue!(plaintext_code: SecureRandom.hex(20), client_id: in_flight.client_id,
      redirect_uri: "https://app.example.com/cb", account: owner)
    refreshed = register!
    StandardId::RefreshToken.create!(account: owner, client_application: refreshed, token_digest: Digest::SHA256.hexdigest(SecureRandom.uuid), expires_at: 30.days.from_now)
    deregistered = register!
    StandardId::ClientGrant.create!(account: owner, client_id: deregistered.client_id, scope: "mcp")
    token = StandardId::RefreshToken.create!(account: owner, client_application: deregistered, token_digest: Digest::SHA256.hexdigest(SecureRandom.uuid), expires_at: 30.days.from_now)
    StandardId::Oauth::ClientRegistration.deregister(deregistered)
    static = StandardId::ClientApplication.create!(owner: owner, name: "Static", redirect_uris: "https://app.example.com/cb", scopes: "read")
    static.update_columns(created_at: 30.days.ago)

    expect(described_class.perform_now).to eq(2)

    expect(StandardId::ClientApplication.exists?(stale.id)).to be(false)
    expect(StandardId::ClientApplication.exists?(deregistered.id)).to be(false)
    expect(token.reload.revoked_at).to be_present
    [fresh, granted, in_flight, refreshed, static].each do |kept|
      expect(StandardId::ClientApplication.exists?(kept.id)).to be(true), "expected #{kept.name} to be kept"
    end
  end

  it "is a no-op before migration 20261020120000 has run" do
    allow(StandardId::ClientApplication).to receive(:registration_management_column?).and_return(false)
    register!
    expect { expect(described_class.perform_now).to eq(0) }.not_to change(StandardId::ClientApplication, :count)
  end
end
