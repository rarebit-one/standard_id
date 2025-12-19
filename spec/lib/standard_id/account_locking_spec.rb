require "rails_helper"

RSpec.describe StandardId::AccountLocking do
  let(:account) { Account.create!(name: "Test", email: "test-#{SecureRandom.hex(4)}@example.com") }
  let(:admin) { Account.create!(name: "Admin", email: "admin-#{SecureRandom.hex(4)}@example.com") }

  describe "locked predicates" do
    context "when locked is false (default)" do
      it "reports unlocked by default" do
        expect(account.locked?).to be false
        expect(account.unlocked?).to be true
      end
    end

    context "when locked is true" do
      before { account.update!(locked: true) }

      it "reports locked" do
        expect(account.locked?).to be true
        expect(account.unlocked?).to be false
      end
    end
  end

  describe "#lock!" do
    context "when account is already locked" do
      before { account.update!(locked: true, lock_reason: "Previous reason") }

      it "returns true without emitting event" do
        events = []
        StandardId::Events.subscribe(StandardId::Events::ACCOUNT_LOCKED) do |event|
          events << event
        end

        expect(account.lock!(reason: "New reason")).to be true
        expect(events).to be_empty
        expect(account.reload.lock_reason).to eq("Previous reason")
      end
    end

    context "when account is unlocked" do
      it "sets locked to true" do
        account.lock!(reason: "Policy violation")
        expect(account.locked).to be true
      end

      it "sets locked_at timestamp" do
        account.lock!(reason: "Policy violation")
        expect(account.locked_at).to be_within(1.second).of(Time.current)
      end

      it "sets lock_reason" do
        account.lock!(reason: "Suspicious activity")
        expect(account.lock_reason).to eq("Suspicious activity")
      end

      it "sets locked_by polymorphic reference" do
        account.lock!(reason: "Policy violation", locked_by: admin)
        expect(account.locked_by_id).to eq(admin.id)
        expect(account.locked_by_type).to eq("Account")
      end

      it "emits ACCOUNT_LOCKED event" do
        event_received = nil
        StandardId::Events.subscribe(StandardId::Events::ACCOUNT_LOCKED) do |event|
          event_received = event
        end

        account.lock!(reason: "Policy violation", locked_by: admin)

        expect(event_received).to be_present
        expect(event_received[:account]).to eq(account)
        expect(event_received[:reason]).to eq("Policy violation")
        expect(event_received[:locked_by]).to eq(admin)
      end
    end
  end

  describe "#unlock!" do
    context "when account is already unlocked" do
      it "returns true without emitting event" do
        events = []
        StandardId::Events.subscribe(StandardId::Events::ACCOUNT_UNLOCKED) do |event|
          events << event
        end

        expect(account.unlock!).to be true
        expect(events).to be_empty
      end
    end

    context "when account is locked" do
      before do
        account.update!(
          locked: true,
          locked_at: 1.day.ago,
          lock_reason: "Policy violation",
          locked_by_id: admin.id,
          locked_by_type: "Account"
        )
      end

      it "sets locked to false" do
        account.unlock!
        expect(account.locked).to be false
      end

      it "sets unlocked_at timestamp" do
        account.unlock!
        expect(account.unlocked_at).to be_within(1.second).of(Time.current)
      end

      it "sets unlocked_by polymorphic reference" do
        account.unlock!(unlocked_by: admin)
        expect(account.unlocked_by_id).to eq(admin.id)
        expect(account.unlocked_by_type).to eq("Account")
      end

      it "clears lock_reason" do
        account.unlock!
        expect(account.lock_reason).to be_nil
      end

      it "emits ACCOUNT_UNLOCKED event" do
        event_received = nil
        StandardId::Events.subscribe(StandardId::Events::ACCOUNT_UNLOCKED) do |event|
          event_received = event
        end

        account.unlock!(unlocked_by: admin)

        expect(event_received).to be_present
        expect(event_received[:account]).to eq(account)
        expect(event_received[:unlocked_by]).to eq(admin)
      end

      it "does not create new sessions (user must log in again)" do
        expect {
          account.unlock!(unlocked_by: admin)
        }.not_to change { StandardId::Session.count }
      end
    end
  end

  describe "scopes" do
    it "provides locked and unlocked scopes" do
      locked_account = Account.create!(
        name: "Locked",
        email: "locked-#{SecureRandom.hex(4)}@example.com",
        locked: true
      )
      unlocked_account = Account.create!(
        name: "Unlocked",
        email: "unlocked-#{SecureRandom.hex(4)}@example.com",
        locked: false
      )

      expect(Account.locked).to include(locked_account)
      expect(Account.locked).not_to include(unlocked_account)
      expect(Account.unlocked).to include(unlocked_account)
      expect(Account.unlocked).not_to include(locked_account)
    end
  end

  describe "event subscriptions for enforcement" do
    context "when account is locked" do
      before { account.update!(locked: true, lock_reason: "Suspicious activity") }

      it "raises AccountLockedError on OAUTH_TOKEN_ISSUING" do
        expect {
          StandardId::Events.publish(StandardId::Events::OAUTH_TOKEN_ISSUING, account: account)
        }.to raise_error(StandardId::AccountLockedError) do |error|
          expect(error.account).to eq(account)
          expect(error.lock_reason).to eq("Suspicious activity")
          expect(error.message).to include("Account has been locked")
        end
      end

      it "raises AccountLockedError on SESSION_CREATING" do
        expect {
          StandardId::Events.publish(StandardId::Events::SESSION_CREATING, account: account)
        }.to raise_error(StandardId::AccountLockedError)
      end

      it "raises AccountLockedError on SESSION_VALIDATING" do
        expect {
          StandardId::Events.publish(StandardId::Events::SESSION_VALIDATING, account: account)
        }.to raise_error(StandardId::AccountLockedError)
      end
    end

    context "when account is unlocked" do
      before { account.update!(locked: false) }

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

  describe "AccountLockedError" do
    it "includes lock metadata" do
      account.update!(locked: true, lock_reason: "Policy violation", locked_at: Time.current)

      error = StandardId::AccountLockedError.new(account)

      expect(error.account).to eq(account)
      expect(error.lock_reason).to eq("Policy violation")
      expect(error.locked_at).to eq(account.locked_at)
      expect(error.message).to eq("Account has been locked: Policy violation")
    end

    it "handles nil lock_reason" do
      account.update!(locked: true, lock_reason: nil)

      error = StandardId::AccountLockedError.new(account)

      expect(error.message).to eq("Account has been locked")
    end
  end
end
