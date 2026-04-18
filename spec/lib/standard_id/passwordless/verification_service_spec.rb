require "rails_helper"

RSpec.describe StandardId::Passwordless::VerificationService do
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
    context "with email" do
      it "returns success with valid code and existing account" do
        account = create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(email: email, code: otp_code, request: request)

        expect(result.success?).to be true
        expect(result.account).to eq(account)
        expect(result.challenge).to be_present
        expect(result.challenge).to be_used
        expect(result.error).to be_nil
      end

      it "creates a new account when no identifier exists" do
        new_email = "new@example.com"
        create_challenge(channel: "email", target: new_email)

        # The dummy app's Account model has constraints (name + email required)
        # that don't match how real host apps handle auto-creation via
        # identifiers_attributes. We pre-create the record and stub create!
        # so the strategy's find_or_create_account path is exercised without
        # hitting the dummy model's validation constraints.
        new_account = Account.create!(name: "Auto", email: new_email)
        StandardId::EmailIdentifier.create!(account: new_account, value: new_email, verified_at: Time.current)
        allow(Account).to receive(:create!)
          .with(hash_including(identifiers_attributes: kind_of(Array)))
          .and_return(new_account)

        result = described_class.verify(email: new_email, code: otp_code, request: request)

        expect(result.success?).to be true
        expect(result.account).to eq(new_account)
      end

      it "returns failure when code is blank" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(email: email, code: "", request: request)

        expect(result.success?).to be false
        expect(result.error).to eq("Code is required")
      end

      it "returns failure when code is wrong" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(email: email, code: "000000", request: request)

        expect(result.success?).to be false
        expect(result.error).to eq("Invalid or expired verification code")
      end

      it "returns failure when no active challenge exists" do
        create_email_account(email)

        result = described_class.verify(email: email, code: otp_code, request: request)

        expect(result.success?).to be false
        expect(result.error).to eq("Invalid or expired verification code")
      end

      it "returns failure for expired challenges" do
        create_email_account(email)
        create_challenge(channel: "email", target: email, expires_at: 1.minute.ago)

        result = described_class.verify(email: email, code: otp_code, request: request)

        expect(result.success?).to be false
        expect(result.error).to eq("Invalid or expired verification code")
      end

      it "returns failure for already-used challenges" do
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)
        challenge.use!

        result = described_class.verify(email: email, code: otp_code, request: request)

        expect(result.success?).to be false
        expect(result.error).to eq("Invalid or expired verification code")
      end

      it "verifies against the most recently created challenge" do
        account = create_email_account(email)
        old_code = "111111"
        new_code = "222222"

        create_challenge(channel: "email", target: email, code: old_code)
        create_challenge(channel: "email", target: email, code: new_code)

        result = described_class.verify(email: email, code: new_code, request: request)

        expect(result.success?).to be true
        expect(result.account).to eq(account)
      end

      it "rejects the old code when multiple active challenges exist" do
        create_email_account(email)
        old_code = "111111"
        new_code = "222222"

        create_challenge(channel: "email", target: email, code: old_code)
        create_challenge(channel: "email", target: email, code: new_code)

        result = described_class.verify(email: email, code: old_code, request: request)

        expect(result.success?).to be false
      end
    end

    context "with phone (SMS)" do
      it "returns success with valid code and existing account" do
        account = create_phone_account(phone)
        create_challenge(channel: "sms", target: phone)

        result = described_class.verify(phone: phone, code: otp_code, request: request)

        expect(result.success?).to be true
        expect(result.account).to eq(account)
        expect(result.challenge).to be_used
      end
    end

    context "with connection:/username: interface" do
      it "returns success when called with connection: 'email' and username:" do
        account = create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(connection: "email", username: email, code: otp_code, request: request)

        expect(result.success?).to be true
        expect(result.account).to eq(account)
        expect(result.challenge).to be_present
        expect(result.challenge).to be_used
      end

      it "returns success when called with connection: 'sms' and username:" do
        account = create_phone_account(phone)
        create_challenge(channel: "sms", target: phone)

        result = described_class.verify(connection: "sms", username: phone, code: otp_code, request: request)

        expect(result.success?).to be true
        expect(result.account).to eq(account)
        expect(result.challenge).to be_used
      end

      it "returns failure with wrong code when using connection:/username:" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(connection: "email", username: email, code: "000000", request: request)

        expect(result.success?).to be false
        expect(result.error).to eq("Invalid or expired verification code")
      end

      it "raises InvalidRequestError for unsupported connection type" do
        expect {
          described_class.verify(connection: "carrier_pigeon", username: "bird", code: otp_code, request: request)
        }.to raise_error(StandardId::InvalidRequestError, /Unsupported connection type/)
      end

      it "raises InvalidRequestError when connection: is provided without username:" do
        expect {
          described_class.verify(connection: "email", code: otp_code, request: request)
        }.to raise_error(StandardId::InvalidRequestError, /username: is required when connection: is provided/)
      end

      it "raises InvalidRequestError when connection: is provided with blank username:" do
        expect {
          described_class.verify(connection: "email", username: "", code: otp_code, request: request)
        }.to raise_error(StandardId::InvalidRequestError, /username: is required when connection: is provided/)
      end
    end

    context "argument validation" do
      it "raises InvalidRequestError when neither email nor phone is provided" do
        expect {
          described_class.verify(code: otp_code, request: request)
        }.to raise_error(StandardId::InvalidRequestError, /Either email: or phone: must be provided/)
      end
    end

    context "failed attempt tracking" do
      it "increments attempt count in challenge metadata on wrong code" do
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        described_class.verify(email: email, code: "000000", request: request)

        expect(challenge.reload.metadata["attempts"]).to eq(1)
      end

      it "returns the attempt count in the result" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(email: email, code: "000000", request: request)

        expect(result.attempts).to eq(1)
      end

      it "locks the challenge after max_attempts" do
        allow(StandardId.config.passwordless).to receive(:max_attempts).and_return(3)
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        3.times do
          described_class.verify(email: email, code: "000000", request: request)
        end

        expect(challenge.reload).to be_used

        # Even the correct code should fail now
        result = described_class.verify(email: email, code: otp_code, request: request)
        expect(result.success?).to be false
      end

      it "does not increment attempts on correct code" do
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        described_class.verify(email: email, code: otp_code, request: request)

        expect(challenge.reload.metadata["attempts"]).to be_nil
      end
    end

    context "constant-time comparison" do
      it "uses secure_compare for OTP verification" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).at_least(:once).and_call_original

        described_class.verify(email: email, code: otp_code, request: request)
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

        described_class.verify(email: email, code: otp_code, request: request)

        expect(validated_events.size).to eq(1)
        expect(validated_events.first.payload[:channel]).to eq("email")
        expect(verified_events.size).to eq(1)
        expect(verified_events.first.payload[:channel]).to eq("email")
      ensure
        StandardId::Events.unsubscribe(sub1, sub2)
      end

      it "emits OTP_VALIDATION_FAILED and PASSWORDLESS_CODE_FAILED on wrong code" do
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

        described_class.verify(email: email, code: "000000", request: request)

        expect(failed_events.size).to eq(1)
        expect(failed_events.first.payload[:identifier]).to eq(email)
        expect(failed_events.first.payload[:attempts]).to eq(1)
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

        described_class.verify(email: email, code: "000000", request: request)

        expect(failed_events).to be_empty
      ensure
        StandardId::Events.unsubscribe(sub)
      end
    end

    context "result object" do
      it "returns a result with expected attributes on success" do
        account = create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(email: email, code: otp_code, request: request)

        expect(result).to respond_to(:success?, :account, :challenge, :error, :attempts)
        expect(result.success?).to be true
        expect(result.account).to eq(account)
        expect(result.error).to be_nil
      end

      it "returns a result with expected attributes on failure" do
        result = described_class.verify(email: email, code: otp_code, request: request)

        expect(result.success?).to be false
        expect(result.account).to be_nil
        expect(result.challenge).to be_nil
        expect(result.error).to be_a(String)
      end
    end

    context "code stripping" do
      it "strips whitespace from code" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        result = described_class.verify(email: email, code: "  #{otp_code}  ", request: request)

        expect(result.success?).to be true
      end
    end

    context "bypass_code" do
      let(:bypass_code) { "BYPASS-E2E-999" }

      context "when bypass_code is configured and submitted code matches" do
        before do
          allow(StandardId.config.passwordless).to receive(:bypass_code).and_return(bypass_code)
        end

        it "returns success without requiring a CodeChallenge" do
          account = create_email_account(email)

          result = described_class.verify(email: email, code: bypass_code, request: request)

          expect(result.success?).to be true
          expect(result.account).to eq(account)
          expect(result.challenge).to be_nil
          expect(result.error).to be_nil
        end

        it "uses secure_compare for the bypass code comparison" do
          create_email_account(email)

          expect(ActiveSupport::SecurityUtils).to receive(:secure_compare)
            .with(bypass_code, bypass_code)
            .and_call_original

          described_class.verify(email: email, code: bypass_code, request: request)
        end

        it "works with phone/SMS channel" do
          account = create_phone_account(phone)

          result = described_class.verify(phone: phone, code: bypass_code, request: request)

          expect(result.success?).to be true
          expect(result.account).to eq(account)
        end

        it "emits OTP_VALIDATED event with bypass: true" do
          create_email_account(email)

          expect(StandardId::Events).to receive(:publish).with(
            StandardId::Events::OTP_VALIDATED,
            hash_including(bypass: true)
          )

          described_class.verify(email: email, code: bypass_code, request: request)
        end

        it "raises in production environment" do
          allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

          expect {
            described_class.verify(email: email, code: bypass_code, request: request)
          }.to raise_error(RuntimeError, /must not be set in production/)
        end
      end

      context "when bypass_code is configured but submitted code does not match" do
        before do
          allow(StandardId.config.passwordless).to receive(:bypass_code).and_return(bypass_code)
        end

        it "falls through to normal verification flow" do
          create_email_account(email)

          result = described_class.verify(email: email, code: "wrong-code", request: request)

          expect(result.success?).to be false
          expect(result.error).to eq("Invalid or expired verification code")
        end

        it "succeeds with correct OTP code and active challenge" do
          account = create_email_account(email)
          create_challenge(channel: "email", target: email)

          result = described_class.verify(email: email, code: otp_code, request: request)

          expect(result.success?).to be true
          expect(result.account).to eq(account)
        end
      end

      context "when bypass_code is nil (default)" do
        before do
          allow(StandardId.config.passwordless).to receive(:bypass_code).and_return(nil)
        end

        it "does not enter the bypass branch" do
          create_email_account(email)
          create_challenge(channel: "email", target: email)

          result = described_class.verify(email: email, code: otp_code, request: request)

          expect(result.success?).to be true
          expect(result.challenge).to be_present
        end
      end
    end

    context "concurrent use protection" do
      it "uses pessimistic locking when consuming the challenge" do
        create_email_account(email)
        create_challenge(channel: "email", target: email)

        # Verify that lock is called during verification
        expect(StandardId::CodeChallenge).to receive(:lock).and_call_original

        described_class.verify(email: email, code: otp_code, request: request)
      end

      it "rejects a racing verifier when the challenge was consumed between select and lock" do
        # Simulates the window between the initial `active` SELECT and the
        # pessimistic `lock.find_by(id: ...)` re-fetch. If a concurrent
        # transaction marks the row used in that gap, the verifier must
        # return :not_found — even when the submitted code is correct.
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        # Intercept `find_by` only on the specific relation returned by
        # CodeChallenge.lock so we don't accidentally stub unrelated find_by
        # calls made during account resolution or elsewhere in the stack.
        original_lock = StandardId::CodeChallenge.method(:lock)
        hijacked = false
        allow(StandardId::CodeChallenge).to receive(:lock).and_wrap_original do |m, *args|
          relation = m.call(*args)
          allow(relation).to receive(:find_by).and_wrap_original do |inner, *inner_args|
            result = inner.call(*inner_args)
            if !hijacked && result.is_a?(StandardId::CodeChallenge)
              hijacked = true
              # A concurrent transaction consumes the challenge in the gap.
              StandardId::CodeChallenge.where(id: result.id).update_all(used_at: Time.current)
              result.reload
            end
            result
          end
          relation
        end

        result = described_class.verify(email: email, code: otp_code, request: request)

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
        expect(challenge.reload).to be_used
      end

      it "only lets one of two racing correct-code verifiers succeed" do
        # Direct simulation of the race: the first verifier is suspended
        # after selecting the challenge but before locking it; the second
        # verifier runs to completion and consumes the challenge; then the
        # first resumes and must observe the consumed state.
        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        original_lock = StandardId::CodeChallenge.method(:lock)
        first_call = true
        allow(StandardId::CodeChallenge).to receive(:lock) do
          if first_call
            first_call = false
            # Another verification sneaks in and consumes the challenge
            # before this caller has taken the row lock.
            StandardId::CodeChallenge.where(id: challenge.id).update_all(used_at: Time.current)
          end
          original_lock.call
        end

        result = described_class.verify(email: email, code: otp_code, request: request)

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
        expect(challenge.reload).to be_used
      end
    end

    context "per-challenge attempt ceiling" do
      it "burns the challenge after :max_attempts_per_challenge incorrect submissions" do
        allow(StandardId.config.passwordless).to receive(:max_attempts_per_challenge).and_return(5)
        allow(StandardId.config.passwordless).to receive(:max_attempts).and_return(100)

        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        4.times do
          result = described_class.verify(email: email, code: "000000", request: request)
          expect(result.error_code).to eq(:invalid_code)
        end

        result = described_class.verify(email: email, code: "000000", request: request)
        expect(result.error_code).to eq(:max_attempts)
        expect(challenge.reload).to be_used
      end

      it "rejects subsequent attempts even from a different IP once the ceiling is hit" do
        allow(StandardId.config.passwordless).to receive(:max_attempts_per_challenge).and_return(3)

        create_email_account(email)
        create_challenge(channel: "email", target: email)

        # Simulate requests from a rotating set of IPs — the ceiling is
        # per-challenge, not per-IP, so the Nth+1 attempt must fail even
        # from a brand-new source address.
        3.times do |i|
          ip_request = instance_double("ActionDispatch::Request", remote_ip: "10.0.0.#{i + 1}", user_agent: "RSpec")
          described_class.verify(email: email, code: "000000", request: ip_request)
        end

        fresh_ip_request = instance_double("ActionDispatch::Request", remote_ip: "203.0.113.99", user_agent: "RSpec")
        result = described_class.verify(email: email, code: "000000", request: fresh_ip_request)

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
      end

      it "falls back to :max_attempts when :max_attempts_per_challenge is nil" do
        allow(StandardId.config.passwordless).to receive(:max_attempts_per_challenge).and_return(nil)
        allow(StandardId.config.passwordless).to receive(:max_attempts).and_return(2)

        create_email_account(email)
        challenge = create_challenge(channel: "email", target: email)

        described_class.verify(email: email, code: "000000", request: request)
        result = described_class.verify(email: email, code: "000000", request: request)

        expect(result.error_code).to eq(:max_attempts)
        expect(challenge.reload).to be_used
      end
    end

    context "allow_registration parameter" do
      context "when allow_registration: true (default)" do
        it "creates a new account when no identifier exists" do
          new_email = "reg-new@example.com"
          create_challenge(channel: "email", target: new_email)

          new_account = Account.create!(name: "Auto", email: new_email)
          StandardId::EmailIdentifier.create!(account: new_account, value: new_email, verified_at: Time.current)
          allow(Account).to receive(:create!)
            .with(hash_including(identifiers_attributes: kind_of(Array)))
            .and_return(new_account)

          result = described_class.verify(email: new_email, code: otp_code, request: request, allow_registration: true)

          expect(result.success?).to be true
          expect(result.account).to eq(new_account)
        end

        it "returns existing account without creating a new one" do
          account = create_email_account(email)
          create_challenge(channel: "email", target: email)

          result = described_class.verify(email: email, code: otp_code, request: request, allow_registration: true)

          expect(result.success?).to be true
          expect(result.account).to eq(account)
        end
      end

      context "when allow_registration: false" do
        it "returns success for existing accounts" do
          account = create_email_account(email)
          create_challenge(channel: "email", target: email)

          result = described_class.verify(email: email, code: otp_code, request: request, allow_registration: false)

          expect(result.success?).to be true
          expect(result.account).to eq(account)
        end

        it "returns failure when no account exists" do
          new_email = "noreg@example.com"
          create_challenge(channel: "email", target: new_email)

          result = described_class.verify(email: new_email, code: otp_code, request: request, allow_registration: false)

          expect(result.success?).to be false
          expect(result.error).to eq("No account found for this email address")
          expect(result.account).to be_nil
        end

        it "does not consume the challenge when account is not found" do
          new_email = "noreg2@example.com"
          challenge = create_challenge(channel: "email", target: new_email)

          described_class.verify(email: new_email, code: otp_code, request: request, allow_registration: false)

          expect(challenge.reload).not_to be_used
        end

        it "does not emit OTP_VALIDATED events when account is not found" do
          new_email = "noreg3@example.com"
          create_challenge(channel: "email", target: new_email)

          validated_events = []
          sub = StandardId::Events.subscribe(StandardId::Events::OTP_VALIDATED) do |event|
            validated_events << event
          end

          described_class.verify(email: new_email, code: otp_code, request: request, allow_registration: false)

          expect(validated_events).to be_empty
        ensure
          StandardId::Events.unsubscribe(sub)
        end
      end

      context "with connection:/username: interface" do
        it "passes allow_registration through" do
          new_email = "noreg-conn@example.com"
          create_challenge(channel: "email", target: new_email)

          result = described_class.verify(
            connection: "email",
            username: new_email,
            code: otp_code,
            request: request,
            allow_registration: false
          )

          expect(result.success?).to be false
          expect(result.error).to eq("No account found for this email address")
        end
      end

      context "with bypass_code" do
        let(:bypass_code) { "BYPASS-REG-TEST" }

        before do
          allow(StandardId.config.passwordless).to receive(:bypass_code).and_return(bypass_code)
        end

        it "returns failure when allow_registration: false and no account exists" do
          result = described_class.verify(email: "noone@example.com", code: bypass_code, request: request, allow_registration: false)

          expect(result.success?).to be false
          expect(result.error).to eq("No account found for this email address")
        end

        it "returns success when allow_registration: false and account exists" do
          account = create_email_account(email)

          result = described_class.verify(email: email, code: bypass_code, request: request, allow_registration: false)

          expect(result.success?).to be true
          expect(result.account).to eq(account)
        end
      end
    end
  end
end
