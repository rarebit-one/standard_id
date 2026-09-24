require "rails_helper"

RSpec.describe StandardId::Otp do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec", params: {}) }
  let(:email)  { "widget-user@example.com" }
  let(:phone)  { "+14155550199" }
  let(:realm)  { "widget_contact_verification" }

  def create_email_account(addr)
    account = Account.create!(name: "Widget User", email: addr)
    StandardId::EmailIdentifier.create!(account: account, value: addr, verified_at: Time.current)
    account
  end

  describe ".issue" do
    context "delivery: :manual" do
      it "creates a challenge in the requested realm and returns the raw code" do
        result = described_class.issue(
          realm: realm,
          target: email,
          channel: :email,
          request: request,
          delivery: :manual
        )

        expect(result.success?).to be true
        expect(result.challenge).to be_a(StandardId::CodeChallenge)
        expect(result.challenge.realm).to eq(realm)
        expect(result.challenge.channel).to eq("email")
        expect(result.challenge.target).to eq(email)
        expect(result.code).to eq(result.challenge.code)
        expect(result.code).to match(/\A\d{6}\z/)
      end

      it "publishes the code with skip_sender so no subscriber delivers it" do
        codes = capture_passwordless_codes

        described_class.issue(
          realm: realm,
          target: email,
          channel: :email,
          request: request,
          delivery: :manual
        )

        expect(codes).to be_empty
        expect(codes.events.map { |e| [e[:skip_sender], e[:delivery]] }).to eq([[true, :manual]])
      end

      it "honors code_length, expires_in, and metadata" do
        result = described_class.issue(
          realm: realm,
          target: email,
          channel: :email,
          request: request,
          delivery: :manual,
          code_length: 8,
          expires_in: 120,
          metadata: { purpose: "demo" }
        )

        expect(result.code).to match(/\A\d{8}\z/)
        expect(result.challenge.metadata["purpose"]).to eq("demo")
        expect(result.challenge.expires_at).to be_within(5.seconds).of(120.seconds.from_now)
      end

      context "when c.passwordless.delivery is :built_in" do
        before do
          # The engine attaches exactly one PasswordlessDeliverySubscriber at
          # boot, and spec/support/event_subscriber_isolation.rb restores that
          # baseline after every example, so no manual clear/attach is needed.
          allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)
        end

        # Before this regression was fixed, BaseStrategy#start! emitted
        # PASSWORDLESS_CODE_GENERATED unconditionally. PasswordlessDeliverySubscriber
        # gated only on c.passwordless.delivery, so manual callers received
        # a duplicate email on top of their own out-of-band delivery.
        it "does not enqueue the bundled mailer (manual means manual)" do
          expect {
            described_class.issue(
              realm: realm, target: email, channel: :email,
              request: request, delivery: :manual
            )
          }.not_to have_enqueued_mail(StandardId::PasswordlessMailer, :otp_email)
        end
      end

      it "invalidates prior active challenges in the same realm+channel+target" do
        first = described_class.issue(
          realm: realm, target: email, channel: :email,
          request: request, delivery: :manual
        )
        second = described_class.issue(
          realm: realm, target: email, channel: :email,
          request: request, delivery: :manual
        )

        expect(first.challenge.reload).to be_used
        expect(second.challenge.reload).to be_active
      end
    end

    context "delivery: :custom" do
      it "publishes the code to the host's subscriber with delivery: :custom" do
        codes = capture_passwordless_codes

        result = described_class.issue(
          realm: realm, target: email, channel: :email,
          request: request, delivery: :custom
        )

        expect(codes).to contain_exactly([email, result.challenge.code])
        expect(codes.events.map { |e| [e[:realm], e[:delivery], e[:skip_sender]] }).to eq([[realm, :custom, false]])
        expect(result.success?).to be true
        expect(result.code).to be_nil
      end

      it "publishes sms codes too" do
        codes = capture_passwordless_codes

        described_class.issue(
          realm: realm, target: phone, channel: :sms,
          request: request, delivery: :custom
        )

        expect(codes).to contain_exactly([phone, kind_of(String)])
      end

      it "needs no sender callback (the 0.42 hard requirement is gone)" do
        result = described_class.issue(
          realm: realm, target: email, channel: :email,
          request: request, delivery: :custom
        )

        expect(result.success?).to be true
      end

      it "keeps the bundled mailer out even when c.passwordless.delivery is :built_in" do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)

        expect {
          described_class.issue(
            realm: realm, target: email, channel: :email,
            request: request, delivery: :custom
          )
        }.not_to have_enqueued_mail(StandardId::PasswordlessMailer, :otp_email)
      end
    end

    context "delivery: :built_in" do
      before do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)
      end

      it "enqueues the bundled verification email (not the sign-in one) for a non-authentication realm" do
        expect {
          described_class.issue(
            realm: realm, target: email, channel: :email,
            request: request, delivery: :built_in
          )
        }.to have_enqueued_mail(StandardId::PasswordlessMailer, :verification_email)
      end

      it "enqueues the sign-in email for the authentication realm" do
        expect {
          described_class.issue(
            realm: StandardId::Otp::DEFAULT_REALM, target: email, channel: :email,
            request: request, delivery: :built_in
          )
        }.to have_enqueued_mail(StandardId::PasswordlessMailer, :otp_email)
      end

      it "publishes the event with delivery: :built_in (subscribers may also deliver)" do
        codes = capture_passwordless_codes

        described_class.issue(
          realm: realm, target: email, channel: :email,
          request: request, delivery: :built_in
        )

        expect(codes.events.map { |e| e[:delivery] }).to eq([:built_in])
      end
    end

    describe "PASSWORDLESS_CODE_SENT delivery_status" do
      def sent_statuses
        statuses = []
        subscription = StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_SENT) { |e| statuses << e[:delivery_status] }
        yield
        statuses
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end

      def issue(**opts)
        described_class.issue(realm: realm, target: email, channel: :email, request: request, **opts)
      end

      it "is \"sent\" when the built-in mailer enqueued the email" do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)

        expect(sent_statuses { issue }).to eq(["sent"])
      end

      it "is \"failed\" when the built-in mailer was responsible but could not enqueue" do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)
        allow(StandardId::PasswordlessMailer).to receive(:with).and_raise(StandardError, "SMTP down")

        expect(sent_statuses { issue }).to eq(["failed"])
      end

      it "is \"failed\" when Active Job refuses the enqueue without raising" do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)
        refused = instance_double(ActionMailer::MessageDelivery, deliver_later: false)
        mailer = double("parameterized mailer", verification_email: refused, otp_email: refused)
        allow(StandardId::PasswordlessMailer).to receive(:with).and_return(mailer)

        expect(sent_statuses { issue }).to eq(["failed"])
      end

      it "is \"delegated\" when a host subscriber delivers (global :custom)" do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:custom)

        expect(sent_statuses { issue }).to eq(["delegated"])
      end

      it "is \"delegated\" for Otp.issue(delivery: :custom) even under a global :built_in" do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)

        expect(sent_statuses { issue(delivery: :custom) }).to eq(["delegated"])
      end

      it "is \"delegated\" for SMS (there is no built-in SMS delivery)" do
        allow(StandardId.config.passwordless).to receive(:delivery).and_return(:built_in)

        statuses = sent_statuses do
          described_class.issue(realm: realm, target: phone, channel: :sms, request: request)
        end
        expect(statuses).to eq(["delegated"])
      end

      it "is not emitted for delivery: :manual" do
        expect(sent_statuses { issue(delivery: :manual) }).to eq([])
      end
    end

    context "validation" do
      it "raises InvalidRequestError for blank realm (matches Otp.verify)" do
        expect {
          described_class.issue(
            realm: "", target: email, channel: :email,
            request: request, delivery: :manual
          )
        }.to raise_error(StandardId::InvalidRequestError, /realm: is required/)
      end

      it "rejects unsupported channel" do
        expect {
          described_class.issue(
            realm: realm, target: email, channel: :carrier_pigeon,
            request: request, delivery: :manual
          )
        }.to raise_error(StandardId::InvalidRequestError, /Unsupported channel/)
      end

      it "rejects unsupported delivery mode" do
        expect {
          described_class.issue(
            realm: realm, target: email, channel: :email,
            request: request, delivery: :carrier_pigeon
          )
        }.to raise_error(StandardId::InvalidRequestError, /Unsupported delivery/)
      end

      it "returns failure for invalid email format" do
        result = described_class.issue(
          realm: realm, target: "not-an-email", channel: :email,
          request: request, delivery: :manual
        )
        expect(result.success?).to be false
        expect(result.error_code).to eq(:invalid_request)
        expect(result.error_message).to match(/email/i)
      end

      it "returns :invalid_request for a blank target" do
        result = described_class.issue(
          realm: realm, target: "   ", channel: :email,
          request: request, delivery: :manual
        )
        expect(result.success?).to be false
        expect(result.error_code).to eq(:invalid_request)
        expect(result.error_message).to match(/target: is required/)
      end

      it "returns :invalid_request for a nil target" do
        result = described_class.issue(
          realm: realm, target: nil, channel: :email,
          request: request, delivery: :manual
        )
        expect(result.success?).to be false
        expect(result.error_code).to eq(:invalid_request)
      end
    end

    context "without a request" do
      it "still succeeds (uses NullRequest)" do
        result = described_class.issue(
          realm: realm, target: email, channel: :email,
          delivery: :manual
        )
        expect(result.success?).to be true
        expect(result.challenge.ip_address).to be_nil
        expect(result.challenge.user_agent).to be_nil
      end
    end
  end

  describe ".verify" do
    it "succeeds with a freshly issued manual-delivery code" do
      issued = described_class.issue(
        realm: realm, target: email, channel: :email,
        request: request, delivery: :manual
      )

      result = described_class.verify(
        realm: realm, target: email, channel: :email,
        code: issued.code, request: request
      )

      expect(result.success?).to be true
      expect(result.challenge).to be_used
    end

    it "fails with wrong code and increments attempts" do
      issued = described_class.issue(
        realm: realm, target: email, channel: :email,
        request: request, delivery: :manual
      )

      result = described_class.verify(
        realm: realm, target: email, channel: :email,
        code: "000000", request: request
      )

      expect(result.success?).to be false
      expect(result.error_code).to eq(:invalid_code)
      expect(issued.challenge.reload.metadata["attempts"]).to eq(1)
    end

    it "returns :not_found when no challenge exists (still uses secure_compare)" do
      expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).at_least(:once).and_call_original

      result = described_class.verify(
        realm: realm, target: email, channel: :email,
        code: "000000", request: request
      )

      expect(result.success?).to be false
      expect(result.error_code).to eq(:not_found)
    end

    it "returns :not_found for expired challenges (filtered out by .active scope)" do
      StandardId::CodeChallenge.create!(
        realm: realm, channel: "email", target: email,
        code: "123456", expires_at: 1.minute.ago
      )

      result = described_class.verify(
        realm: realm, target: email, channel: :email,
        code: "123456", request: request
      )

      expect(result.success?).to be false
      # When the challenge is expired, VerificationService's .active scope
      # filters it out so the result is :not_found, not :expired.
      expect(result.error_code).to eq(:not_found)
    end

    it "returns :max_attempts after exhausting attempts" do
      allow(StandardId.config.passwordless).to receive(:max_attempts).and_return(3)
      described_class.issue(
        realm: realm, target: email, channel: :email,
        request: request, delivery: :manual
      )

      2.times do
        described_class.verify(
          realm: realm, target: email, channel: :email,
          code: "000000", request: request
        )
      end
      final = described_class.verify(
        realm: realm, target: email, channel: :email,
        code: "000000", request: request
      )

      expect(final.success?).to be false
      expect(final.error_code).to eq(:max_attempts)
    end

    it "rejects blank code with :blank_code" do
      result = described_class.verify(
        realm: realm, target: email, channel: :email,
        code: "", request: request
      )

      expect(result.success?).to be false
      expect(result.error_code).to eq(:blank_code)
    end

    context "sms channel" do
      let(:phone) { "+15551234567" }

      it "verifies a freshly issued manual-delivery SMS code" do
        issued = described_class.issue(
          realm: realm, target: phone, channel: :sms,
          request: request, delivery: :manual
        )

        result = described_class.verify(
          realm: realm, target: phone, channel: :sms,
          code: issued.code, request: request
        )

        expect(result.success?).to be true
        expect(result.challenge).to be_used
      end

      it "returns :not_found for a missing SMS challenge" do
        result = described_class.verify(
          realm: realm, target: phone, channel: :sms,
          code: "000000", request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
      end

      it "does not cross realms across SMS / email for the same target" do
        issued_email = described_class.issue(
          realm: realm, target: "mix@example.com", channel: :email,
          request: request, delivery: :manual
        )

        # A phone-channel verify with the same code must not match the
        # email-channel challenge.
        result = described_class.verify(
          realm: realm, target: phone, channel: :sms,
          code: issued_email.code, request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
      end
    end
  end

  describe "realm isolation" do
    it "a challenge issued for realm A is not matched when verifying realm B" do
      issued = described_class.issue(
        realm: "realm_a", target: email, channel: :email,
        request: request, delivery: :manual
      )

      result = described_class.verify(
        realm: "realm_b", target: email, channel: :email,
        code: issued.code, request: request
      )

      expect(result.success?).to be false
      expect(result.error_code).to eq(:not_found)

      # Issuing in realm_a must not consume the challenge for realm_a.
      still_active = described_class.verify(
        realm: "realm_a", target: email, channel: :email,
        code: issued.code, request: request
      )
      expect(still_active.success?).to be true
    end

    it "issuing for realm A does not invalidate active challenges in realm B" do
      issued_a = described_class.issue(
        realm: "realm_a", target: email, channel: :email,
        request: request, delivery: :manual
      )
      described_class.issue(
        realm: "realm_b", target: email, channel: :email,
        request: request, delivery: :manual
      )

      expect(issued_a.challenge.reload).to be_active
    end
  end

  describe "bypass_code" do
    let(:bypass_code) { "OTP-BYPASS-TEST" }

    context "in non-production with bypass_code configured" do
      before do
        allow(StandardId.config.passwordless).to receive(:bypass_code).and_return(bypass_code)
      end

      it "succeeds for a non-authentication realm without an account" do
        result = described_class.verify(
          realm: realm, target: email, channel: :email,
          code: bypass_code, request: request
        )

        expect(result.success?).to be true
        expect(result.account).to be_nil
        expect(result.challenge).to be_nil
      end

      it "succeeds for any arbitrary realm" do
        result = described_class.verify(
          realm: "some_other_realm", target: "noone@example.com", channel: :email,
          code: bypass_code, request: request
        )
        expect(result.success?).to be true
      end

      it "still uses the existing VerificationService bypass for the authentication realm" do
        account = create_email_account(email)

        result = described_class.verify(
          realm: "authentication", target: email, channel: :email,
          code: bypass_code, request: request
        )

        expect(result.success?).to be true
        expect(result.account).to eq(account)
      end

      it "falls through to regular verification when code does not match bypass" do
        issued = described_class.issue(
          realm: realm, target: email, channel: :email,
          request: request, delivery: :manual
        )

        result = described_class.verify(
          realm: realm, target: email, channel: :email,
          code: issued.code, request: request
        )
        expect(result.success?).to be true
      end

      it "raises when run in production" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

        expect {
          described_class.verify(
            realm: realm, target: email, channel: :email,
            code: bypass_code, request: request
          )
        }.to raise_error(RuntimeError, /must not be set in production/)
      end

      it "honors production_env_detector over Rails.env" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
        allow(StandardId.config.passwordless).to receive(:production_env_detector).and_return(-> { true })

        expect {
          described_class.verify(
            realm: realm, target: email, channel: :email,
            code: bypass_code, request: request
          )
        }.to raise_error(RuntimeError, /must not be set in production/)
      end

      it "allows bypass under Rails.env.production? when production_env_detector returns false" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        allow(StandardId.config.passwordless).to receive(:production_env_detector).and_return(-> { false })

        result = described_class.verify(
          realm: realm, target: email, channel: :email,
          code: bypass_code, request: request
        )

        expect(result.success?).to be true
      end
    end

    context "with bypass_code unset" do
      before do
        allow(StandardId.config.passwordless).to receive(:bypass_code).and_return(nil)
      end

      it "does not short-circuit" do
        result = described_class.verify(
          realm: realm, target: email, channel: :email,
          code: "000000", request: request
        )

        expect(result.success?).to be false
        expect(result.error_code).to eq(:not_found)
      end
    end
  end
end
