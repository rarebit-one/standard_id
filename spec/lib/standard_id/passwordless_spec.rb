require "rails_helper"

RSpec.describe StandardId::Passwordless do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }
  let(:email) { "user@example.com" }
  let(:phone) { "+14155550123" }
  let(:otp_code) { "123456" }

  before do
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil)
    allow(StandardId.config).to receive(:passwordless_sms_sender).and_return(nil)
  end

  def create_challenge(channel:, target:, code: otp_code, expires_at: 10.minutes.from_now)
    StandardId::CodeChallenge.create!(
      realm: "authentication",
      channel: channel,
      target: target,
      code: code,
      expires_at: expires_at,
      ip_address: "127.0.0.1",
      user_agent: "RSpec"
    )
  end

  def create_email_account(email)
    account = Account.create!(name: "Test User", email: email)
    StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
    account
  end

  def create_phone_account(phone, email: "phone-user@example.com")
    account = Account.create!(name: "Test User", email: email)
    StandardId::PhoneNumberIdentifier.create!(account: account, value: phone, verified_at: Time.current)
    account
  end

  describe ".verify" do
    context "with email connection" do
      it "returns success with valid code and existing account" do
        account = create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(
          username: email,
          code: otp_code,
          connection: "email",
          request: request
        )

        expect(result.success?).to be true
        expect(result.account).to eq(account)
        expect(result.challenge).to be_present
        expect(result.challenge).to be_used
        expect(result.error).to be_nil
        expect(result.error_code).to be_nil
      end

      it "creates a new account when no identifier exists" do
        new_email = "new@example.com"
        create_challenge(channel: "email", target: new_email)

        new_account = Account.create!(name: "Auto", email: new_email)
        StandardId::EmailIdentifier.create!(account: new_account, value: new_email, verified_at: Time.current)
        allow(Account).to receive(:create!)
          .with(hash_including(identifiers_attributes: kind_of(Array)))
          .and_return(new_account)

        result = described_class.verify(
          username: new_email,
          code: otp_code,
          connection: "email",
          request: request
        )

        expect(result.success?).to be true
        expect(result.account).to eq(new_account)
      end
    end

    context "with SMS connection" do
      it "returns success with valid code and existing account" do
        account = create_phone_account(phone)
        create_challenge(channel: "sms", target: phone)

        result = described_class.verify(
          username: phone,
          code: otp_code,
          connection: "sms",
          request: request
        )

        expect(result.success?).to be true
        expect(result.account).to eq(account)
        expect(result.challenge).to be_used
      end
    end

    context "error codes" do
      it "returns :blank_code when code is empty" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(
          username: email,
          code: "",
          connection: "email",
          request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:blank_code)
        expect(result.error).to eq("Code is required")
      end

      it "returns :not_found when no active challenge exists" do
        create_email_account(email)

        result = described_class.verify(
          username: email,
          code: otp_code,
          connection: "email",
          request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
        expect(result.attempts).to eq(0)
      end

      it "returns :not_found for expired challenges" do
        create_email_account(email)
        create_challenge(channel: "email", target: email, expires_at: 1.minute.ago)

        result = described_class.verify(
          username: email,
          code: otp_code,
          connection: "email",
          request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
      end

      it "returns :not_found for already-used challenges" do
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)
        challenge.use!

        result = described_class.verify(
          username: email,
          code: otp_code,
          connection: "email",
          request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
      end

      it "returns :not_found when the challenge is consumed between select and lock" do
        # Lookup, lock, verify, and consume happen inside a single transaction
        # with a row lock, but the active? recheck after the lock still has
        # to handle the race where a concurrent transaction consumed the
        # challenge between the initial SELECT and the lock acquisition.
        # In that case we now return :not_found (no active challenge exists).
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        # Simulate a concurrent consumption that happens between the select
        # and the lock by wrapping the lock scope's find_by.
        original_lock = StandardId::CodeChallenge.method(:lock)
        allow(StandardId::CodeChallenge).to receive(:lock) do
          challenge.update_columns(used_at: Time.current)
          original_lock.call
        end

        result = described_class.verify(
          username: email,
          code: otp_code,
          connection: "email",
          request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
      end

      it "returns :invalid_code when code is wrong" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(
          username: email,
          code: "000000",
          connection: "email",
          request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:invalid_code)
        expect(result.attempts).to eq(1)
      end

      it "returns :max_attempts when max failed attempts reached" do
        allow(StandardId.config.passwordless).to receive(:max_attempts).and_return(3)
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        2.times do
          result = described_class.verify(
            username: email, code: "000000", connection: "email", request: request
          )
          expect(result.error_code).to eq(:invalid_code)
        end

        result = described_class.verify(
          username: email, code: "000000", connection: "email", request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:max_attempts)
        expect(result.attempts).to eq(3)
      end

      it "returns :max_attempts and locks the challenge so correct code fails after" do
        allow(StandardId.config.passwordless).to receive(:max_attempts).and_return(2)
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        2.times do
          described_class.verify(
            username: email, code: "000000", connection: "email", request: request
          )
        end

        # Now even the correct code should fail because challenge is used
        result = described_class.verify(
          username: email, code: otp_code, connection: "email", request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
      end
    end

    context "server error handling" do
      it "returns :server_error when account creation raises RecordInvalid" do
        create_challenge(channel: "email", target: email)

        allow_any_instance_of(StandardId::Passwordless::EmailStrategy)
          .to receive(:find_or_create_account)
          .and_raise(ActiveRecord::RecordInvalid.new(Account.new))

        result = described_class.verify(
          username: email, code: otp_code, connection: "email", request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:server_error)
        expect(result.error).to include("Unable to complete verification")
      end
    end

    context "result object interface" do
      it "exposes all expected attributes on success" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(
          username: email, code: otp_code, connection: "email", request: request
        )

        expect(result).to respond_to(:success?, :account, :challenge, :error, :error_code, :attempts)
        expect(result.success?).to be true
        expect(result.error).to be_nil
        expect(result.error_code).to be_nil
        expect(result.attempts).to be_nil
      end

      it "exposes all expected attributes on failure" do
        result = described_class.verify(
          username: email, code: otp_code, connection: "email", request: request
        )

        expect(result.success?).to be false
        expect(result.account).to be_nil
        expect(result.challenge).to be_nil
        expect(result.error).to be_a(String)
        expect(result.error_code).to be_a(Symbol)
      end
    end

    context "constant-time comparison" do
      it "uses secure_compare for OTP verification" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).at_least(:once).and_call_original

        described_class.verify(
          username: email, code: otp_code, connection: "email", request: request
        )
      end
    end

    context "pessimistic locking" do
      it "uses pessimistic locking when consuming the challenge" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        expect(StandardId::CodeChallenge).to receive(:lock).and_call_original

        described_class.verify(
          username: email, code: otp_code, connection: "email", request: request
        )
      end
    end

    context "failed attempt tracking" do
      it "increments attempt count on wrong code" do
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        described_class.verify(
          username: email, code: "000000", connection: "email", request: request
        )

        expect(challenge.reload.metadata["attempts"]).to eq(1)
      end

      it "does not increment attempts on correct code" do
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        described_class.verify(
          username: email, code: otp_code, connection: "email", request: request
        )

        expect(challenge.reload.metadata["attempts"]).to be_nil
      end
    end

    context "events" do
      it "emits OTP_VALIDATED and PASSWORDLESS_CODE_VERIFIED on success" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        validated_events = []
        verified_events = []

        sub1 = StandardId::Events.subscribe(StandardId::Events::OTP_VALIDATED) do |event|
          validated_events << event
        end
        sub2 = StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_VERIFIED) do |event|
          verified_events << event
        end

        described_class.verify(
          username: email, code: otp_code, connection: "email", request: request
        )

        expect(validated_events.size).to eq(1)
        expect(verified_events.size).to eq(1)
      ensure
        StandardId::Events.unsubscribe(sub1, sub2)
      end

      it "emits failure events on wrong code" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        failed_events = []
        code_failed_events = []

        sub1 = StandardId::Events.subscribe(StandardId::Events::OTP_VALIDATION_FAILED) do |event|
          failed_events << event
        end
        sub2 = StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_FAILED) do |event|
          code_failed_events << event
        end

        described_class.verify(
          username: email, code: "000000", connection: "email", request: request
        )

        expect(failed_events.size).to eq(1)
        expect(code_failed_events.size).to eq(1)
      ensure
        StandardId::Events.unsubscribe(sub1, sub2)
      end

      it "does not emit failure events when no challenge exists" do
        create_email_account(email)

        failed_events = []

        sub = StandardId::Events.subscribe(StandardId::Events::OTP_VALIDATION_FAILED) do |event|
          failed_events << event
        end

        described_class.verify(
          username: email, code: "000000", connection: "email", request: request
        )

        expect(failed_events).to be_empty
      ensure
        StandardId::Events.unsubscribe(sub)
      end
    end

    context "argument validation" do
      it "raises InvalidRequestError for unsupported connection type" do
        expect {
          described_class.verify(
            username: "bird", code: otp_code, connection: "carrier_pigeon", request: request
          )
        }.to raise_error(StandardId::InvalidRequestError, /Unsupported connection type/)
      end
    end

    context "code stripping" do
      it "strips whitespace from code" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(
          username: email, code: "  #{otp_code}  ", connection: "email", request: request
        )

        expect(result.success?).to be true
      end
    end

    context "delegates to VerificationService" do
      it "calls VerificationService.verify with correct parameters" do
        mock_result = StandardId::Passwordless::VerificationService::Result.new(
          "success?": true,
          account: nil,
          challenge: nil,
          error: nil,
          error_code: nil,
          attempts: nil
        )

        expect(StandardId::Passwordless::VerificationService).to receive(:verify).with(
          connection: "email",
          username: email,
          code: otp_code,
          request: request,
          allow_registration: true
        ).and_return(mock_result)

        described_class.verify(
          username: email, code: otp_code, connection: "email", request: request
        )
      end
    end
  end
end
