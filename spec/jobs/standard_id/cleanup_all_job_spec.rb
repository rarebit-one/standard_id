require "rails_helper"

RSpec.describe StandardId::CleanupAllJob, type: :job do
  let(:jobs) do
    [
      StandardId::CleanupExpiredSessionsJob,
      StandardId::CleanupExpiredRefreshTokensJob,
      StandardId::CleanupExpiredAuthorizationCodesJob,
      StandardId::CleanupExpiredCodeChallengesJob
    ]
  end

  it "runs all four cleanup jobs inline" do
    expect(described_class.jobs).to eq(jobs)
    jobs.each { |job| expect(job).to receive(:perform_now).with(no_args).ordered }

    described_class.perform_now
  end

  it "deletes expired rows end to end" do
    account = Account.create!(name: "Cleanup", email: "cleanup-all-#{SecureRandom.hex(4)}@example.com")
    old = StandardId::BrowserSession.create!(account: account, expires_at: 30.days.ago, ip_address: "127.0.0.1", user_agent: "Test")
    challenge = StandardId::CodeChallenge.create!(realm: "authentication", channel: "email", target: "x@example.com",
                                                  code: "123456", expires_at: 30.days.ago)

    described_class.perform_now

    expect(StandardId::Session.exists?(old.id)).to be(false)
    expect(StandardId::CodeChallenge.exists?(challenge.id)).to be(false)
  end

  it "keeps going when one job fails, then re-raises the first error" do
    first_error = RuntimeError.new("lock timeout")
    allow(jobs[0]).to receive(:perform_now).and_raise(first_error)
    allow(jobs[1]).to receive(:perform_now).and_raise(ArgumentError, "second")
    expect(jobs[2]).to receive(:perform_now)
    expect(jobs[3]).to receive(:perform_now)

    expect { described_class.perform_now }.to raise_error(first_error)
  end

  it "can be subclassed (e.g. to attach a cron monitor)" do
    subclass = Class.new(described_class)
    jobs.each { |job| allow(job).to receive(:perform_now) }

    subclass.new.perform

    jobs.each { |job| expect(job).to have_received(:perform_now) }
  end
end
