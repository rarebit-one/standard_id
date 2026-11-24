require "rails_helper"

# account.status_changed (AccountStatus) and credential.client_secret.created /
# rotated (ClientSecretCredential, ClientApplication#rotate_client_secret!).
RSpec.describe "Account status and client secret events" do
  def capture(*names)
    events = []
    subs = StandardId::Events.subscribe(*names) { |e| events << [e.short_name, e.payload] }
    yield
    events
  ensure
    StandardId::Events.unsubscribe(subs) if subs
  end

  describe "account.status_changed" do
    let(:account) { Account.create!(name: "Status", email: "status-#{SecureRandom.hex(4)}@example.com") }

    it "is published after account.deactivated, with both statuses" do
      events = capture(StandardId::Events::ACCOUNT_DEACTIVATED, StandardId::Events::ACCOUNT_STATUS_CHANGED) { account.deactivate! }

      expect(events.map(&:first)).to eq([StandardId::Events::ACCOUNT_DEACTIVATED, StandardId::Events::ACCOUNT_STATUS_CHANGED])
      payload = events.last.last
      expect(payload).to include(previous_status: "active", status: "inactive")
      expect(payload[:account].id).to eq(account.id)
    end

    it "is published after account.activated" do
      account.deactivate!

      events = capture(StandardId::Events::ACCOUNT_ACTIVATED, StandardId::Events::ACCOUNT_STATUS_CHANGED) { account.activate! }

      expect(events.map(&:first)).to eq([StandardId::Events::ACCOUNT_ACTIVATED, StandardId::Events::ACCOUNT_STATUS_CHANGED])
      expect(events.last.last).to include(previous_status: "inactive", status: "active")
    end

    it "is published for a status written directly" do
      events = capture(StandardId::Events::ACCOUNT_STATUS_CHANGED) { account.update!(status: :inactive) }

      expect(events.size).to eq(1)
    end

    it "is not published when the status does not change" do
      expect(capture(StandardId::Events::ACCOUNT_STATUS_CHANGED) { account.activate! }).to be_empty
      expect(capture(StandardId::Events::ACCOUNT_STATUS_CHANGED) { account.update!(name: "Renamed") }).to be_empty
    end
  end

  describe "client secrets" do
    let(:client) do
      StandardId::ClientApplication.create!(
        owner: Account.create!(name: "Owner", email: "owner-#{SecureRandom.hex(4)}@example.com"),
        name: "Secret Client",
        client_id: "secret_client_#{SecureRandom.hex(4)}",
        redirect_uris: "https://example.com/callback",
        scopes: "read"
      )
    end

    def secret_values(payload)
      payload.values.flatten.map(&:to_s)
    end

    describe "credential.client_secret.created" do
      it "is published with ids only: never the secret, its digest or the record" do
        secret = nil
        events = capture(StandardId::Events::CREDENTIAL_CLIENT_SECRET_CREATED) do
          secret = client.create_client_secret!(name: "Primary", client_secret: "plain-secret-123")
        end

        expect(events.size).to eq(1)
        payload = events.first.last
        expect(payload).to include(credential_id: secret.id, client_application_id: client.id,
                                   client_id: client.client_id, name: "Primary")
        expect(payload.values).to all(satisfy { |v| !v.is_a?(ActiveRecord::Base) })
        expect(secret_values(payload)).not_to include("plain-secret-123", secret.client_secret_digest)
      end

      it "is not published for a create that rolls back" do
        events = capture(StandardId::Events::CREDENTIAL_CLIENT_SECRET_CREATED) do
          ActiveRecord::Base.transaction do
            client.create_client_secret!(name: "Doomed")
            raise ActiveRecord::Rollback
          end
        end

        expect(events).to be_empty
      end

      it "does not fail the create when a subscriber raises" do
        allow(Rails.error).to receive(:report)
        sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_CLIENT_SECRET_CREATED) { raise "subscriber down" }
        begin
          expect { client.create_client_secret!(name: "Survivor") }.to change(StandardId::ClientSecretCredential, :count).by(1)
        ensure
          StandardId::Events.unsubscribe(sub)
        end
        expect(Rails.error).to have_received(:report).with(an_instance_of(RuntimeError), hash_including(handled: true))
      end
    end

    describe "credential.client_secret.rotated" do
      it "is published after created, naming the new secret and the ones it revoked" do
        old_secret = client.create_client_secret!(name: "Old")
        already_revoked = client.create_client_secret!(name: "Gone")
        already_revoked.revoke!

        new_secret = nil
        events = capture(StandardId::Events::CREDENTIAL_CLIENT_SECRET_CREATED, StandardId::Events::CREDENTIAL_CLIENT_SECRET_ROTATED) do
          new_secret = client.rotate_client_secret!(client_secret: "rotated-secret-456")
        end

        expect(events.map(&:first)).to eq([StandardId::Events::CREDENTIAL_CLIENT_SECRET_CREATED, StandardId::Events::CREDENTIAL_CLIENT_SECRET_ROTATED])
        payload = events.last.last
        expect(payload).to include(credential_id: new_secret.id, client_application_id: client.id,
                                   client_id: client.client_id, revoked_credential_ids: [old_secret.id])
        expect(payload[:old_secret_revoked_at]).to be_within(1.second).of(old_secret.reload.revoked_at)
        expect(secret_values(payload)).not_to include("rotated-secret-456", new_secret.client_secret_digest)
      end

      it "is not published by creating a secret alone" do
        expect(capture(StandardId::Events::CREDENTIAL_CLIENT_SECRET_ROTATED) { client.create_client_secret! }).to be_empty
      end
    end
  end
end
