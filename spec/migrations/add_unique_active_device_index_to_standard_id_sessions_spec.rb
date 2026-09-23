require "rails_helper"
require_relative "../../db/migrate/20260924000000_add_unique_active_device_index_to_standard_id_sessions"

RSpec.describe AddUniqueActiveDeviceIndexToStandardIdSessions do
  let(:connection) { ActiveRecord::Base.connection }
  let(:index_name) { described_class::INDEX_NAME }
  let(:account) { Account.create!(name: "Dup User", email: "dup-#{SecureRandom.hex(4)}@example.com") }

  def run(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  def device_session!(device_id:, created_at:, revoked_at: nil)
    StandardId::DeviceSession.create!(
      account: account, device_id: device_id, device_agent: "Kit/1.0",
      ip_address: "10.0.0.1", expires_at: 1.day.from_now,
      created_at: created_at, revoked_at: revoked_at
    )
  end

  # SQLite DDL is transactional, so the per-example transaction restores the
  # schema.rb index after each example.
  before { run(:down) }

  it "detaches all but the newest duplicate active row, revoking nothing, then adds the index" do
    oldest = device_session!(device_id: "dev-a", created_at: 3.days.ago)
    middle = device_session!(device_id: "dev-a", created_at: 2.days.ago)
    newest = device_session!(device_id: "dev-a", created_at: 1.day.ago)
    revoked = device_session!(device_id: "dev-a", created_at: 1.hour.ago, revoked_at: 1.minute.ago)
    other = device_session!(device_id: "dev-b", created_at: 1.day.ago)

    run(:up)

    expect(newest.reload.device_id).to eq("dev-a")
    expect(oldest.reload.device_id).to eq("dev-a:detached:#{oldest.id}")
    expect(middle.reload.device_id).to eq("dev-a:detached:#{middle.id}")
    expect(revoked.reload.device_id).to eq("dev-a")
    expect(other.reload.device_id).to eq("dev-b")
    expect([oldest, middle, newest, other].map { |s| s.reload.revoked_at }).to all(be_nil)

    index = connection.indexes(:standard_id_sessions).find { |i| i.name == index_name }
    expect(index).to be_present
    expect(index.unique).to be(true)
    expect(index.columns).to eq(%w[account_id device_id])
    expect(index.where).to eq("revoked_at IS NULL AND device_id IS NOT NULL")
  end

  it "is idempotent" do
    run(:up)
    expect { run(:up) }.not_to raise_error
    expect(connection.index_exists?(:standard_id_sessions, [:account_id, :device_id], name: index_name)).to be(true)
  end

  it "allows many revoked rows but only one active row per device" do
    run(:up)
    device_session!(device_id: "dev-a", created_at: 2.days.ago, revoked_at: 1.day.ago)
    device_session!(device_id: "dev-a", created_at: 1.day.ago, revoked_at: 1.hour.ago)
    device_session!(device_id: "dev-a", created_at: 1.minute.ago)

    expect { device_session!(device_id: "dev-a", created_at: Time.current) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "removes the index on down" do
    run(:up)
    run(:down)
    expect(connection.index_name_exists?(:standard_id_sessions, index_name)).to be_falsey
  end
end
