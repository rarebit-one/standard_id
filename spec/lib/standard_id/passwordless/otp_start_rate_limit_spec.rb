require "rails_helper"

# The lib-level OTP start limits (rate_limits.otp_start_per_target /
# otp_start_per_ip) enforced inside Passwordless::BaseStrategy#start!, and the
# per-target serialisation of the cooldown check. Until these existed the gem's
# only limits were controller before_actions, so a host that reached the
# strategy from its own controllers, an operation or a job had none.
RSpec.describe "Passwordless OTP start rate limits", type: :model do
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "203.0.113.9", user_agent: "RSpec") }
  let(:strategy) { StandardId::Passwordless::EmailStrategy.new(request) }

  before do
    allow(StandardId::RateLimiter::STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
    allow(StandardId::Passwordless).to receive(:retry_delay).and_return(0)
  end

  def start!(username, strategy: self.strategy)
    strategy.start!(connection: "email", username: username)
  end

  describe "per target (default 5 per 15 minutes)" do
    it "refuses the sixth start for one address, case-insensitively" do
      5.times { start!("user@example.com") }

      expect { start!("User@Example.com") }.to raise_error(StandardId::RateLimitExceededError)
      expect(StandardId::CodeChallenge.where(target: "user@example.com").count).to eq(5)
    end

    it "does not count another address" do
      5.times { start!("user@example.com") }

      expect { start!("other@example.com") }.not_to raise_error
    end

    it "budgets realms separately: a verification code and a login code for one address" do
      5.times { start!("user@example.com") }
      verification = StandardId::Passwordless::EmailStrategy.new(request, realm: "verification")

      expect { start!("user@example.com", strategy: verification) }.not_to raise_error
    end

    it "is off at 0" do
      allow(StandardId.config.rate_limits).to receive(:otp_start_per_target).and_return(0)

      expect { 7.times { start!("user@example.com") } }.not_to raise_error
    end
  end

  describe "per IP (off by default)" do
    it "does not limit by IP unless configured" do
      expect { 12.times { |i| start!("user#{i}@example.com") } }.not_to raise_error
    end

    it "refuses across addresses once the configured per-IP ceiling is hit" do
      allow(StandardId.config.rate_limits).to receive(:otp_start_per_ip).and_return(2)
      2.times { |i| start!("user#{i}@example.com") }

      expect { start!("user9@example.com") }.to raise_error(StandardId::RateLimitExceededError)
    end

    it "skips the IP limit when the caller has no request (Otp.issue from a job)" do
      allow(StandardId.config.rate_limits).to receive(:otp_start_per_ip).and_return(1)

      expect {
        3.times { |i| StandardId::Otp.issue(realm: "jobs", target: "user#{i}@example.com", delivery: :manual) }
      }.not_to raise_error
    end
  end

  describe "through the public entry points" do
    it "Otp.issue returns a failed result with error_code :rate_limited" do
      5.times { StandardId::Otp.issue(realm: "verification", target: "user@example.com", request: request, delivery: :manual) }

      result = StandardId::Otp.issue(realm: "verification", target: "user@example.com", request: request, delivery: :manual)

      expect(result.success?).to be false
      expect(result.error_code).to eq(:rate_limited)
      expect(result.error_message).to eq("Too many requests. Please try again later.")
    end
  end

  describe "cooldown serialisation (#lock_target!)" do
    it "takes a transaction-scoped advisory lock on PostgreSQL, keyed per realm, channel and target" do
      connection = StandardId::CodeChallenge.connection
      allow(connection).to receive(:adapter_name).and_return("PostgreSQL")
      allow(connection).to receive(:execute).and_call_original
      allow(connection).to receive(:execute).with(/pg_advisory_xact_lock/).and_return(nil)

      start!("user@example.com")

      expect(connection).to have_received(:execute)
        .with("SELECT pg_advisory_xact_lock(hashtext('standard_id:otp:authentication:email:user@example.com'))")
    end

    it "issues no lock statement on other adapters" do
      connection = StandardId::CodeChallenge.connection
      allow(connection).to receive(:execute).and_call_original

      start!("user@example.com")

      expect(connection).not_to have_received(:execute).with(/pg_advisory/)
    end

    it "runs the cooldown check and the challenge creation inside one transaction" do
      allow(StandardId::Passwordless).to receive(:retry_delay).and_return(30)
      start!("user@example.com")

      expect { start!("user@example.com") }.to raise_error(StandardId::InvalidRequestError, /wait \d+ seconds?/)
      expect(StandardId::CodeChallenge.where(target: "user@example.com").count).to eq(1)
    end
  end
end
