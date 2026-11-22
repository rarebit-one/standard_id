require "rails_helper"

RSpec.describe StandardId::StepUp do
  include ActiveSupport::Testing::TimeHelpers
  include RequestSpecHelpers

  let(:email) { "step-up-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "Sup3r-secret!" }
  let(:account) { create_account_with_password(email: email, password: password) }

  before do
    StandardId.config.step_up.enabled = true
    capture_passwordless_codes
  end

  def events_for(*names)
    events = []
    subs = names.map { |name| StandardId::Events.subscribe(name) { |e| events << [name, e.payload] } }
    yield
    events
  ensure
    subs&.each { |s| StandardId::Events.unsubscribe(s) }
  end

  def browser_session(authenticated_at:)
    StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1", user_agent: "RSpec",
      expires_at: 1.day.from_now, authenticated_at: authenticated_at)
  end

  describe ".ensure_usable!" do
    it "refuses while c.step_up.enabled is false" do
      StandardId.config.step_up.enabled = false

      expect { described_class.ensure_usable! }.to raise_error(StandardId::ConfigurationError, /c\.step_up\.enabled/)
    end

    it "names the migration when the column is missing" do
      allow(described_class).to receive(:session_column?).and_return(false)

      expect { described_class.ensure_usable! }.to raise_error(StandardId::ConfigurationError, /20261123000000/)
    end

    it "passes once enabled and migrated" do
      expect { described_class.ensure_usable! }.not_to raise_error
    end
  end

  describe ".recent?" do
    it "is true within the window and false outside it" do
      fresh = browser_session(authenticated_at: 2.minutes.ago)
      stale = browser_session(authenticated_at: 10.minutes.ago)

      expect(described_class.recent?(fresh, within: 5.minutes)).to be(true)
      expect(described_class.recent?(stale, within: 5.minutes)).to be(false)
      expect(described_class.recent?(stale, within: 15.minutes)).to be(true)
    end

    it "defaults the window to c.step_up.max_age" do
      StandardId.config.step_up.max_age = 60
      session = browser_session(authenticated_at: 2.minutes.ago)

      expect(described_class.recent?(session)).to be(false)
    end

    it "is false for a session that never authenticated (remember-me) and for nil" do
      expect(described_class.recent?(browser_session(authenticated_at: nil), within: 1.hour)).to be(false)
      expect(described_class.recent?(nil, within: 1.hour)).to be(false)
    end

    it "is false for a time in the future" do
      expect(described_class.recent?(browser_session(authenticated_at: 1.minute.from_now), within: 1.hour)).to be(false)
    end

    it "reads a decoded access token's auth_time claim" do
      decoded = StandardId::JwtService.decode_session(StandardId::JwtService.encode({ sub: account.id, auth_time: 1.minute.ago.to_i }))
      undated = StandardId::JwtService.decode_session(StandardId::JwtService.encode({ sub: account.id }))
      garbled = StandardId::JwtService.decode_session(StandardId::JwtService.encode({ sub: account.id, auth_time: "soon" }))

      expect(described_class.recent?(decoded, within: 5.minutes)).to be(true)
      expect(described_class.recent?(undated, within: 5.minutes)).to be(false)
      expect(described_class.recent?(garbled, within: 5.minutes)).to be(false)
    end
  end

  describe ".mark!" do
    it "stamps the session row and nothing else" do
      session = browser_session(authenticated_at: nil)
      freeze_time do
        expect { described_class.mark!(session) }.not_to change { session.reload.updated_at }
        expect(session.reload.authenticated_at).to eq(Time.current)
      end
    end

    it "ignores what is not a session row" do
      expect(described_class.mark!(Struct.new(:id).new(1))).to be_nil
    end
  end

  describe ".destination_for" do
    it "prefers a verified e-mail address" do
      expect(described_class.destination_for(account)).to eq(["email", email])
    end

    it "falls back to a verified phone number, never an unverified identifier" do
      StandardId::EmailIdentifier.where(account: account).update_all(verified_at: nil)
      StandardId::PhoneNumberIdentifier.create!(account: account, value: "+15555550123", verified_at: Time.current)

      expect(described_class.destination_for(account)).to eq(["sms", "+15555550123"])
    end

    it "is nil without a verified identifier" do
      StandardId::EmailIdentifier.where(account: account).update_all(verified_at: nil)

      expect(described_class.destination_for(account)).to be_nil
    end
  end

  describe ".start" do
    it "issues a code in the step-up realm and publishes STEP_UP_STARTED" do
      result = nil
      events = events_for(StandardId::Events::STEP_UP_STARTED) { result = described_class.start(account: account) }

      expect(result).to be_success
      expect(result.channel).to eq("email")
      expect(issued_otp_code(email)).to be_present
      expect(StandardId::CodeChallenge.where(realm: "step_up", target: email)).to exist
      expect(events.map(&:first)).to eq([StandardId::Events::STEP_UP_STARTED])
      expect(events.first.last).to include(account: account, channel: "email")
    end

    it "answers :cooldown, with no event, when a code was sent moments ago" do
      StandardId.config.passwordless.retry_delay = 60
      described_class.start(account: account)
      result = nil
      events = events_for(StandardId::Events::STEP_UP_STARTED, StandardId::Events::STEP_UP_FAILED) { result = described_class.start(account: account) }

      expect(result).not_to be_success
      expect(result.error_code).to eq(:cooldown)
      expect(events).to be_empty
    end

    it "fails with STEP_UP_FAILED when there is nowhere to send a code" do
      StandardId::EmailIdentifier.where(account: account).update_all(verified_at: nil)
      result = nil
      events = events_for(StandardId::Events::STEP_UP_FAILED) { result = described_class.start(account: account) }

      expect(result.error_code).to eq(:no_verified_identifier)
      expect(events.first.last).to include(stage: :start, error_code: "no_verified_identifier")
    end
  end

  describe ".verify" do
    before { described_class.start(account: account) }

    def verify(code: issued_otp_code(email), password: self.password)
      described_class.verify(account: account, code: code, password: password)
    end

    it "succeeds with the code and the password, publishing STEP_UP_SUCCEEDED" do
      result = nil
      events = events_for(StandardId::Events::STEP_UP_SUCCEEDED, StandardId::Events::STEP_UP_FAILED) { result = verify }

      expect(result).to be_success
      expect(events.map(&:first)).to eq([StandardId::Events::STEP_UP_SUCCEEDED])
      expect(events.first.last).to include(account: account, channel: "email", methods: %w[otp password])
    end

    it "spends the code, so it cannot be replayed" do
      code = issued_otp_code(email)
      expect(verify(code: code)).to be_success
      expect(verify(code: code)).not_to be_success
    end

    it "refuses a wrong code" do
      result = nil
      events = events_for(StandardId::Events::STEP_UP_FAILED) { result = verify(code: "000000") }

      expect(result).not_to be_success
      expect(result.error_code).to eq(:invalid_code)
      expect(events.first.last).to include(stage: :verify, error_code: "invalid_code")
    end

    it "refuses a wrong or missing password, and the code is spent" do
      code = issued_otp_code(email)
      result = verify(code: code, password: "Wr0ng-password!")

      expect(result.error_code).to eq(:invalid_password)
      expect(verify(code: code)).not_to be_success

      described_class.start(account: account)
      expect(verify(password: nil).error_code).to eq(:invalid_password)
    end

    it "needs only the code when require_password is off" do
      StandardId.config.step_up.require_password = false

      expect(verify(password: nil)).to be_success
    end

    it "needs only the code for an account without a password" do
      passwordless = Account.create!(name: "No Password", email: "nopw-#{SecureRandom.hex(4)}@example.com")
      StandardId::EmailIdentifier.create!(account: passwordless, value: passwordless.email, verified_at: Time.current)
      described_class.start(account: passwordless)

      result = described_class.verify(account: passwordless, code: issued_otp_code(passwordless.email))
      expect(result).to be_success
    end

    it "does not accept a sign-in code from the authentication realm" do
      StandardId::Otp.issue(realm: StandardId::Otp::DEFAULT_REALM, target: email, channel: :email)

      expect(verify(code: issued_otp_code(email)).error_code).to eq(:invalid_code)
    end

    it "does not accept a step-up code issued to another account for the same address" do
      challenge = StandardId::CodeChallenge.where(realm: "step_up", target: email).last
      challenge.update_column(:metadata, challenge.metadata.merge("account_id" => "someone-else"))

      expect(verify.error_code).to eq(:invalid_code)
    end
  end
end
