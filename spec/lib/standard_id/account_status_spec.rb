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

      # NOT `Events.publish(SESSION_VALIDATING, account: account)`. That form
      # supplied the very key the real publisher omitted, so it passed for
      # months while the guard was inert in production (rarebit-ops#306).
      # Drive the real publisher instead. Full HTTP coverage of both engines
      # lives in spec/requests/standard_id/live_session_account_guard_spec.rb.
      it "raises AccountDeactivatedError when the real web guard validates a live session" do
        expect {
          validate_live_browser_session(account)
        }.to raise_error(StandardId::AccountDeactivatedError, "Account is deactivated")
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

      it "does not raise when the real web guard validates a live session" do
        expect {
          validate_live_browser_session(account)
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

  describe "idempotent subscription registration" do
    it "does not register a second subscription when AccountStatus is included twice" do
      # Guard flag is already true after the initial Account include; re-including
      # from another class should not add a new subscription.
      expect(StandardId::AccountStatus.subscribed).to be true

      before_count = account_status_listeners_count

      second_class = Class.new(ApplicationRecord) do
        self.table_name = Account.table_name
        include StandardId::AccountStatus
      end
      # Reference to prevent removal by GC + warning noise
      second_class.name

      after_count = account_status_listeners_count

      expect(after_count).to eq(before_count)
    end
  end

  def account_status_listeners_count
    # Count distinct ActiveSupport::Notifications subscribers that would be
    # invoked when we publish a SESSION_CREATING event. This is the best
    # practical proxy for "how many AccountStatus guard callbacks are wired
    # up" — if we re-subscribed on re-include, this count would grow.
    ActiveSupport::Notifications.notifier.listeners_for(
      "standard_id.#{StandardId::Events::SESSION_CREATING}"
    ).size
  end
  describe ".deactivated?" do
    it "is false for nil and for an object that does not include the concern" do
      expect(StandardId::AccountStatus.deactivated?(nil)).to be false
      expect(StandardId::AccountStatus.deactivated?(Object.new)).to be false
    end
  end

  describe "config.inactive_account_status = :active" do
    it "is refused at include time rather than collapsing the enum" do
      allow(StandardId.config).to receive(:inactive_account_status).and_return(:active)

      expect {
        Class.new(ApplicationRecord) do
          self.table_name = "accounts"
          include StandardId::AccountStatus
        end
      }.to raise_error(StandardId::ConfigurationError, "inactive_account_status cannot be :active")
    end
  end

  describe "with a renamed deactivated status (config.inactive_account_status = :suspended)" do
    let(:suspendable_class) do
      allow(StandardId.config).to receive(:inactive_account_status).and_return(:suspended)
      Class.new(ApplicationRecord) do
        self.table_name = "accounts"
        # What the ACCOUNT_DEACTIVATED subscriber reaches for; declared by hand
        # because AccountAssociations would derive the FK from this class's name.
        has_many :sessions, class_name: "StandardId::Session", foreign_key: :account_id, inverse_of: false
        include StandardId::AccountStatus
        validates :email, :name, presence: true

        def self.name = "SuspendableAccount"
      end
    end
    let(:suspendable) do
      suspendable_class.create!(name: "Suspendable", email: "suspendable-#{SecureRandom.hex(4)}@example.com")
    end

    it "declares the host's word as the enum key and value, with inactive? as an alias" do
      expect(suspendable_class.statuses).to eq({ "active" => "active", "suspended" => "suspended" })
      expect(suspendable).to respond_to(:suspended?)
      expect(suspendable.suspended?).to be false
      expect(suspendable.inactive?).to be false
    end

    it "deactivate! writes that value and activate! clears it" do
      suspendable.deactivate!
      expect(suspendable.reload.status).to eq("suspended")
      expect(suspendable.suspended?).to be true
      expect(suspendable.inactive?).to be true
      expect(suspendable.deactivated_at).to be_within(1.second).of(Time.current)

      suspendable.activate!
      expect(suspendable.reload.status).to eq("active")
    end

    it "emits ACCOUNT_DEACTIVATED / ACCOUNT_ACTIVATED around the renamed status" do
      received = []
      StandardId::Events.subscribe(StandardId::Events::ACCOUNT_DEACTIVATED, StandardId::Events::ACCOUNT_ACTIVATED) do |event|
        received << [event.name, event[:previous_status]]
      end

      suspendable.deactivate!
      suspendable.activate!

      expect(received.map(&:last)).to eq(%w[active suspended])
      expect(received.map(&:first)).to eq([
        "standard_id.#{StandardId::Events::ACCOUNT_DEACTIVATED}", "standard_id.#{StandardId::Events::ACCOUNT_ACTIVATED}"
      ])
    end

    it "the sign-in / token guard refuses the account with the host's word" do
      suspendable.deactivate!

      expect {
        StandardId::Events.publish(StandardId::Events::OAUTH_TOKEN_ISSUING, account: suspendable)
      }.to raise_error(StandardId::AccountDeactivatedError, "Account is suspended")
      expect {
        StandardId::Events.publish(StandardId::Events::SESSION_CREATING, account: suspendable)
      }.to raise_error(StandardId::AccountDeactivatedError, "Account is suspended")
    end

    it "leaves the default-keyed model untouched" do
      suspendable_class
      expect(Account.statuses).to eq({ "active" => "active", "inactive" => "inactive" })
      expect(account.inactive?).to be false
    end
  end

  describe "without the timestamp columns" do
    it "activate! and deactivate! write only the status" do
      allow(account).to receive(:has_attribute?).and_call_original
      allow(account).to receive(:has_attribute?).with(:deactivated_at).and_return(false)
      allow(account).to receive(:has_attribute?).with(:activated_at).and_return(false)

      expect(account).to receive(:update!).with(status: :inactive).and_call_original
      account.deactivate!
      expect(account).to receive(:update!).with(status: :active).and_call_original
      account.activate!
    end
  end
end
