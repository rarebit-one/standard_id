require "rails_helper"

# Covers the OTP-resend cooldown (passwordless.retry_delay) enforced in
# BaseStrategy#enforce_retry_delay!. The test dummy disables the cooldown by
# default (retry_delay = 0); these specs opt into a non-zero delay.
RSpec.describe "Passwordless retry_delay cooldown", type: :model do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }
  subject(:strategy) { StandardId::Passwordless::EmailStrategy.new(request) }
  let(:username) { "user@example.com" }

  before { allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil) }

  context "when retry_delay is set" do
    before { allow(StandardId::Passwordless).to receive(:retry_delay).and_return(30) }

    it "rejects a resend within the cooldown window" do
      strategy.start!(connection: "email", username: username)

      expect {
        strategy.start!(connection: "email", username: username)
      }.to raise_error(StandardId::InvalidRequestError, /wait \d+ seconds? before requesting another code/)
    end

    it "does not consume the already-issued challenge when rejecting" do
      first = strategy.start!(connection: "email", username: username)

      begin
        strategy.start!(connection: "email", username: username)
      rescue StandardId::InvalidRequestError
        # expected
      end

      expect(first.reload).to be_active
    end

    it "allows a resend once the cooldown has elapsed" do
      strategy.start!(connection: "email", username: username)
      # Back-date the issued challenge past the cooldown window rather than
      # sleeping / relying on time-travel helpers (not wired into this suite).
      StandardId::CodeChallenge.where(target: username).update_all(created_at: 1.minute.ago)

      expect {
        strategy.start!(connection: "email", username: username)
      }.not_to raise_error
    end

    it "does not throttle a different target" do
      strategy.start!(connection: "email", username: username)

      expect {
        strategy.start!(connection: "email", username: "other@example.com")
      }.not_to raise_error
    end
  end

  context "when retry_delay is 0 (disabled)" do
    before { allow(StandardId::Passwordless).to receive(:retry_delay).and_return(0) }

    it "permits back-to-back resends" do
      strategy.start!(connection: "email", username: username)
      expect {
        strategy.start!(connection: "email", username: username)
      }.not_to raise_error
    end
  end
end
