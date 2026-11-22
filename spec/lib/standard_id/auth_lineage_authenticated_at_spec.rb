require "rails_helper"

# StandardId::AuthLineage carries when the authentication happened, for
# step-up (StandardId::StepUp), alongside how it was made.
RSpec.describe StandardId::AuthLineage do
  let(:at) { Time.utc(2026, 11, 23, 8, 30, 15, 123_456) }

  it "leaves the time out of a lineage that has none, so existing comparisons hold" do
    expect(described_class.build(:password)).to eq(auth_method: "password", auth_provider: nil)
    expect(described_class.to_metadata(described_class.build(:password))).to eq("auth_method" => "password")
  end

  it "round-trips the time through metadata to the microsecond" do
    metadata = described_class.to_metadata(described_class.build(:password, authenticated_at: at))

    expect(metadata).to eq("auth_method" => "password", "authenticated_at" => "2026-11-23T08:30:15.123456Z")
    expect(described_class.from_metadata(metadata)[:authenticated_at]).to eq(at)
  end

  it "ignores an unreadable time" do
    expect(described_class.from_metadata("authenticated_at" => "yesterday-ish")).not_to have_key(:authenticated_at)
  end

  it "reads a session's time from its column, not its metadata" do
    account = Account.create!(name: "Lineage", email: "lineage-at@example.com")
    session = StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1", user_agent: "RSpec",
      expires_at: 1.day.from_now, authenticated_at: at, metadata: { "auth_method" => "password", "authenticated_at" => "2001-01-01T00:00:00Z" })

    expect(described_class.from_session(session)).to eq(auth_method: "password", auth_provider: nil, authenticated_at: at)
  end

  it "writes the time onto a refresh token once the column exists" do
    expect(described_class.refresh_token_attributes(described_class.build(:password, authenticated_at: at))).to include(authenticated_at: at)

    allow(StandardId::StepUp).to receive(:refresh_token_column?).and_return(false)
    expect(described_class.refresh_token_attributes(described_class.build(:password, authenticated_at: at))).not_to have_key(:authenticated_at)
  end
end
