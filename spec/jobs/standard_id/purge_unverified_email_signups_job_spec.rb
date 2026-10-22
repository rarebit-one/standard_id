require "rails_helper"

RSpec.describe StandardId::PurgeUnverifiedEmailSignupsJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers
  include RequestSpecHelpers

  before { StandardId.config.email_password.enabled = true }

  # An email + password sign-up as Registration leaves it: an unverified email
  # identifier with a password credential and the code it was sent, all
  # created +age+ ago.
  def pending_signup(email, age: 4.days)
    account = unverified_password_signup(email, age: age)
    StandardId::CodeChallenge.create!(
      realm: StandardId.config.email_password.verification_realm, channel: "email", target: email,
      code: "654321", expires_at: (age - 10.minutes).ago, created_at: age.ago
    )
    account
  end

  # The same rows without a code: what Web::SignupForm leaves.
  def unverified_password_signup(email, age: 4.days)
    account = create_account_with_password(email: email, password: "Sup3r-secret!", name: "Pending")
    StandardId::EmailIdentifier.find_by!(value: email).update_columns(verified_at: nil, created_at: age.ago)
    account
  end

  def gone?(account)
    !Account.exists?(account.id)
  end

  it "removes a stale pending sign-up: credential, identifier and account" do
    account = pending_signup("stale@example.com")

    result = described_class.perform_now

    expect(result).to eq(purged_count: 1, skipped_count: 0)
    expect(gone?(account)).to be(true)
    expect(StandardId::PasswordCredential.where(login: "stale@example.com")).to be_empty
    expect(StandardId::EmailIdentifier.where(value: "stale@example.com")).to be_empty
  end

  it "leaves sign-ups younger than unverified_purge_after alone" do
    account = pending_signup("fresh@example.com", age: 1.day)

    expect(described_class.perform_now).to eq(purged_count: 0, skipped_count: 0)
    expect(gone?(account)).to be(false)
  end

  it "honours older_than_seconds" do
    StandardId.config.email_password.purge_recent_code_window = 30.minutes.to_i
    account = pending_signup("fresh@example.com", age: 2.hours)

    described_class.perform_now(older_than_seconds: 1.hour.to_i)

    expect(gone?(account)).to be(true)
  end

  it "does nothing when email_password is disabled" do
    account = pending_signup("stale@example.com")
    StandardId.config.email_password.enabled = false

    expect(described_class.perform_now).to eq(purged_count: 0, skipped_count: 0)
    expect(gone?(account)).to be(false)
  end

  it "never considers an unverified password sign-up that was not sent a code in the verification realm" do
    web_signup = unverified_password_signup("web@example.com")
    StandardId::CodeChallenge.create!(
      realm: "authentication", channel: "email", target: "web@example.com",
      code: "111111", expires_at: 4.days.ago, created_at: 4.days.ago
    )

    expect(described_class.perform_now).to eq(purged_count: 0, skipped_count: 0)
    expect(gone?(web_signup)).to be(false)
  end

  it "never considers an unverified password sign-up that was never sent a code at all" do
    web_signup = unverified_password_signup("web@example.com")

    expect(described_class.perform_now).to eq(purged_count: 0, skipped_count: 0)
    expect(gone?(web_signup)).to be(false)
  end

  it "warns when the window reaches past how long code challenges are kept" do
    allow(Rails.logger).to receive(:warn)

    described_class.perform_now(older_than_seconds: 8.days.to_i)

    expect(Rails.logger).to have_received(:warn).with(/reaches past the 7 days code challenges are kept/)
  end

  it "never considers a verified identifier" do
    account = pending_signup("verified@example.com")
    StandardId::EmailIdentifier.find_by(value: "verified@example.com").update!(verified_at: Time.current)

    expect(described_class.perform_now).to eq(purged_count: 0, skipped_count: 0)
    expect(gone?(account)).to be(false)
  end

  describe "skips the account at any sign of real use" do
    let!(:account) { pending_signup("used@example.com") }

    after do
      expect(described_class.perform_now).to eq(purged_count: 0, skipped_count: 1)
      expect(gone?(account)).to be(false)
      expect(StandardId::PasswordCredential.where(login: "used@example.com")).to exist
    end

    it "another verified identifier" do
      StandardId::PhoneNumberIdentifier.create!(account: account, value: "+6591234567", verified_at: Time.current)
    end

    it "a provider-linked identifier" do
      StandardId::EmailIdentifier.create!(account: account, value: "used+g@example.com", provider: "google")
    end

    it "a session" do
      StandardId::BrowserSession.create!(account: account, user_agent: "RSpec", expires_at: 1.day.from_now)
    end

    it "a refresh token" do
      StandardId::RefreshToken.create!(account: account, token_digest: Digest::SHA256.hexdigest(SecureRandom.uuid), expires_at: 30.days.from_now)
    end

    it "account_in_use returning true" do
      StandardId.config.email_password.account_in_use = ->(account:) { account.email == "used@example.com" }
    end

    it "a password reset requested in the last day" do
      StandardId.config.cache_store = ActiveSupport::Cache::MemoryStore.new
      StandardId::EmailPassword::DailyLimit.record!(:reset_requested, "used@example.com")
    end

    it "a code requested within purge_recent_code_window" do
      StandardId::CodeChallenge.create!(
        realm: StandardId.config.email_password.verification_realm, channel: "email", target: "used@example.com",
        code: "123456", expires_at: 10.minutes.from_now, ip_address: "127.0.0.1", user_agent: "RSpec"
      )
    end
  end

  it "keeps the account, removing only the sign-up, when another unverified identifier remains" do
    account = pending_signup("first@example.com")
    StandardId::EmailIdentifier.create!(account: account, value: "second@example.com")

    expect(described_class.perform_now).to eq(purged_count: 1, skipped_count: 0)
    expect(gone?(account)).to be(false)
    expect(StandardId::EmailIdentifier.where(value: "first@example.com")).to be_empty
  end

  it "rolls one sign-up back, and carries on, when a guard refuses the delete" do
    blocked = pending_signup("blocked@example.com")
    other = pending_signup("other@example.com")
    allow_any_instance_of(Account).to receive(:destroy!).and_wrap_original do |original, *args|
      raise ActiveRecord::RecordNotDestroyed, "restricted" if original.receiver.id == blocked.id

      original.call(*args)
    end

    expect(described_class.perform_now).to eq(purged_count: 1, skipped_count: 1)
    expect(gone?(other)).to be(true)
    expect(gone?(blocked)).to be(false)
    expect(StandardId::PasswordCredential.where(login: "blocked@example.com")).to exist
  end
end
