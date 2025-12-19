require "rails_helper"

RSpec.describe StandardId::Events::Subscribers::AccountStatusSubscriber do
  let(:account) { Account.create!(name: "Test User", email: "test@example.com") }
  let(:subscriber) { described_class.new }

  before do
    clear_event_subscribers!
    StandardId::BrowserSession.create!(
      account: account,
      expires_at: 1.day.from_now,
      user_agent: "RSpec",
      ip_address: "127.0.0.1"
    )
  end

  describe ".subscribe_to" do
    it "subscribes to ACCOUNT_DEACTIVATED event" do
      expect(described_class.subscribed_events).to include(StandardId::Events::ACCOUNT_DEACTIVATED)
    end
  end

  describe "#call" do
    let(:event) do
      StandardId::Events::Event.new(
        name: "standard_id.#{StandardId::Events::ACCOUNT_DEACTIVATED}",
        payload: { account: },
        started_at: Time.current,
        finished_at: Time.current,
        transaction_id: SecureRandom.hex
      )
    end

    context "when account has sessions association" do
      it "revokes all active sessions for the account" do
        active_sessions = account.sessions.active
        expect(active_sessions.count).to be > 0

        subscriber.call(event)

        active_sessions.reload
        expect(active_sessions.all?(&:revoked?)).to be true
      end

      it "emits SESSION_REVOKED event for each session" do
        events_received = []
        StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) do |e|
          events_received << e
        end

        subscriber.call(event)

        expect(events_received.count).to eq(account.sessions.count)
        events_received.each do |e|
          expect(e[:reason]).to eq("account_deactivated")
        end
      end
    end

    context "when account has no sessions association" do
      let(:account_without_sessions) { Account.create!(name: "Test User 2", email: "test_2@example.com") }
      let(:event_without_sessions) do
        StandardId::Events::Event.new(
          name: "standard_id.#{StandardId::Events::ACCOUNT_DEACTIVATED}",
          payload: { account: account_without_sessions },
          started_at: Time.current,
          finished_at: Time.current,
          transaction_id: SecureRandom.hex
        )
      end

      it "does not raise error" do
        expect { subscriber.call(event_without_sessions) }.not_to raise_error
      end
    end
  end

  describe "integration with Events.publish" do
    before do
      described_class.attach
    end

    after do
      described_class.detach
    end

    it "revokes sessions when ACCOUNT_DEACTIVATED is published" do
      active_sessions = account.sessions.active
      expect(active_sessions.count).to be > 0

      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_DEACTIVATED,
        account: account,
        previous_status: "active"
      )

      active_sessions.reload
      expect(active_sessions.all?(&:revoked?)).to be true
    end
  end
end
