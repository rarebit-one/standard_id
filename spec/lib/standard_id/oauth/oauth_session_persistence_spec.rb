require "rails_helper"

RSpec.describe StandardId::Oauth::OauthSessionPersistence do
  let(:account) { Account.create!(name: "Device User", email: "device-#{SecureRandom.hex(4)}@example.com") }
  let(:request) { instance_double(ActionDispatch::Request, user_agent: "CompanionKit/2.3 iOS", remote_ip: "10.0.0.9") }
  let(:audience) { "companion_kit" }
  let(:device_id) { described_class.stable_device_id(account: account, user_agent: request.user_agent, audience: audience) }

  def upsert!
    described_class.upsert_device_session!(account: account, request: request, audience: audience, grant_type: "social")
  end

  def device_session!(created_at: Time.current, revoked_at: nil, device_id: self.device_id)
    StandardId::DeviceSession.create!(
      account: account,
      device_id: device_id,
      device_agent: "CompanionKit/2.3 iOS",
      ip_address: "10.0.0.1",
      expires_at: 1.day.from_now,
      created_at: created_at,
      revoked_at: revoked_at
    )
  end

  describe ".upsert_device_session!" do
    it "never reuses a revoked row: it starts a new active one" do
      revoked = device_session!(revoked_at: 1.minute.ago)

      session = nil
      expect { session = upsert! }.to change(StandardId::DeviceSession, :count).by(1)

      expect(session.id).not_to eq(revoked.id)
      expect(session).not_to be_revoked
      expect(session.device_id).to eq(device_id)
      expect(revoked.reload).to be_revoked
    end

    it "reuses the active row and bumps its expiry" do
      active = device_session!
      active.update_columns(expires_at: 1.minute.ago)

      expect { expect(upsert!.id).to eq(active.id) }.not_to change(StandardId::DeviceSession, :count)
      expect(active.reload.expires_at).to be > 1.day.from_now
    end

    # Hosts that have not yet run 20260924000000 can still hold duplicate
    # active rows. The choice between them must be deterministic: the newest.
    context "without the unique index (host has not run the migration yet)" do
      before do
        ActiveRecord::Base.connection.remove_index :standard_id_sessions,
          name: "index_standard_id_sessions_on_active_account_device"
      end

      it "reuses the newest active row" do
        device_session!(created_at: 2.days.ago)
        newest = device_session!(created_at: 1.hour.ago)
        device_session!(created_at: 1.minute.ago, revoked_at: 30.seconds.ago)

        expect(upsert!.id).to eq(newest.id)
      end
    end

    # Two first sign-ins for the same device racing past the lookup: the loser's
    # INSERT hits the partial unique index. It must reuse the winner's row, and
    # the enclosing token transaction must remain usable (savepoint).
    it "reuses the winning row when a concurrent insert trips the unique index" do
      winner = device_session!
      # The first lookup misses (the race); the post-violation lookup finds the winner.
      call_count = 0
      allow(described_class).to receive(:active_device_session).and_wrap_original do |original, **kwargs|
        call_count += 1
        call_count == 1 ? nil : original.call(**kwargs)
      end

      result = nil
      ActiveRecord::Base.transaction do
        result = upsert!
        # The outer transaction is still healthy after the rescued violation.
        expect(StandardId::DeviceSession.where(account: account).count).to eq(1)
      end

      expect(result.id).to eq(winner.id)
      expect(call_count).to eq(2)
    end
  end
end
