require "rails_helper"

RSpec.describe StandardId::AccountStatus do
  let(:account) { Account.create!(name: "Test", email: "test-#{SecureRandom.hex(4)}@example.com") }

  describe "status predicates" do
    context "when using default status" do
      it "is active by default" do
        expect(account.active?).to be true
        expect(account.inactive?).to be false
      end
    end

    context "when status is 'active'" do
      before { account.update!(status: :active) }

      it "reports active" do
        expect(account.active?).to be true
        expect(account.inactive?).to be false
      end
    end

    context "when status is 'inactive'" do
      before { account.update!(status: :inactive) }

      it "reports inactive" do
        expect(account.active?).to be false
        expect(account.inactive?).to be true
      end
    end
  end

  describe "#activate!" do
    context "when account is already active" do
      before { account.update!(status: :active) }

      it "returns true without emitting event" do
        events = []
        StandardId::Events.subscribe(StandardId::Events::ACCOUNT_ACTIVATED) do |event|
          events << event
        end

        expect(account.activate!).to be true
        expect(events).to be_empty
      end
    end

    context "when account is inactive" do
      before { account.update!(status: :inactive) }

      it "sets status to active" do
        account.activate!
        expect(account.status).to eq("active")
      end

      it "sets activated_at timestamp" do
        account.activate!
        expect(account.activated_at).to be_within(1.second).of(Time.current)
      end

      it "emits ACCOUNT_ACTIVATED event" do
        event_received = nil
        StandardId::Events.subscribe(StandardId::Events::ACCOUNT_ACTIVATED) do |event|
          event_received = event
        end

        account.activate!

        expect(event_received).to be_present
        expect(event_received[:account]).to eq(account)
        expect(event_received[:previous_status]).to eq("inactive")
      end
    end
  end

  describe "#deactivate!" do
    context "when account is already inactive" do
      before { account.update!(status: :inactive) }

      it "returns true without emitting event" do
        events = []
        StandardId::Events.subscribe(StandardId::Events::ACCOUNT_DEACTIVATED) do |event|
          events << event
        end

        expect(account.deactivate!).to be true
        expect(events).to be_empty
      end
    end

    context "when account is active" do
      before { account.update!(status: :active) }

      it "sets status to inactive" do
        account.deactivate!
        expect(account.status).to eq("inactive")
      end

      it "sets deactivated_at timestamp" do
        account.deactivate!
        expect(account.deactivated_at).to be_within(1.second).of(Time.current)
      end

      it "emits ACCOUNT_DEACTIVATED event" do
        event_received = nil
        StandardId::Events.subscribe(StandardId::Events::ACCOUNT_DEACTIVATED) do |event|
          event_received = event
        end

        account.deactivate!

        expect(event_received).to be_present
        expect(event_received[:account]).to eq(account)
        expect(event_received[:previous_status]).to eq("active")
      end
    end
  end

  describe "enum" do
    it "defines active and inactive statuses" do
      expect(Account.statuses).to eq({ "active" => "active", "inactive" => "inactive" })
    end

    it "provides scopes" do
      active_account = Account.create!(name: "Active", email: "active-#{SecureRandom.hex(4)}@example.com", status: :active)
      inactive_account = Account.create!(name: "Inactive", email: "inactive-#{SecureRandom.hex(4)}@example.com", status: :inactive)

      expect(Account.active).to include(active_account)
      expect(Account.active).not_to include(inactive_account)
      expect(Account.inactive).to include(inactive_account)
      expect(Account.inactive).not_to include(active_account)
    end
  end

  describe "event subscriptions for enforcement" do
    context "when account is inactive" do
      before { account.update!(status: :inactive) }

      it "raises AccountDeactivatedError on OAUTH_TOKEN_ISSUING" do
        expect {
          StandardId::Events.publish(StandardId::Events::OAUTH_TOKEN_ISSUING, account: account)
        }.to raise_error(StandardId::AccountDeactivatedError)
      end

      it "raises AccountDeactivatedError on SESSION_CREATING" do
        expect {
          StandardId::Events.publish(StandardId::Events::SESSION_CREATING, account: account)
        }.to raise_error(StandardId::AccountDeactivatedError)
      end

      it "raises AccountDeactivatedError on SESSION_VALIDATING" do
        expect {
          StandardId::Events.publish(StandardId::Events::SESSION_VALIDATING, account: account)
        }.to raise_error(StandardId::AccountDeactivatedError)
      end
    end

    context "when account is active" do
      before { account.update!(status: :active) }

      it "does not raise on OAUTH_TOKEN_ISSUING" do
        expect {
          StandardId::Events.publish(StandardId::Events::OAUTH_TOKEN_ISSUING, account: account)
        }.not_to raise_error
      end

      it "does not raise on SESSION_CREATING" do
        expect {
          StandardId::Events.publish(StandardId::Events::SESSION_CREATING, account: account)
        }.not_to raise_error
      end

      it "does not raise on SESSION_VALIDATING" do
        expect {
          StandardId::Events.publish(StandardId::Events::SESSION_VALIDATING, account: account)
        }.not_to raise_error
      end
    end

    context "when account is nil" do
      it "does not raise on events" do
        expect {
          StandardId::Events.publish(StandardId::Events::OAUTH_TOKEN_ISSUING, account: nil)
        }.not_to raise_error
      end
    end
  end
end
