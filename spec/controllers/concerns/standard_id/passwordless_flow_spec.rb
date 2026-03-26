require "rails_helper"

RSpec.describe StandardId::PasswordlessFlow do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }
  let(:email) { "user@example.com" }
  let(:otp_code) { "123456" }

  # Build a minimal test class that includes the concern
  let(:controller_class) do
    Class.new do
      include StandardId::PasswordlessFlow

      attr_reader :request

      def initialize(request)
        @request = request
      end
    end
  end

  let(:controller) { controller_class.new(request) }

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

  describe "#generate_passwordless_otp" do
    it "creates a CodeChallenge for the given email" do
      expect {
        controller.send(:generate_passwordless_otp, email: email)
      }.to change(StandardId::CodeChallenge, :count).by(1)

      challenge = StandardId::CodeChallenge.last
      expect(challenge.channel).to eq("email")
      expect(challenge.target).to eq(email)
      expect(challenge.realm).to eq("authentication")
    end

    it "returns the created CodeChallenge" do
      result = controller.send(:generate_passwordless_otp, email: email)
      expect(result).to be_a(StandardId::CodeChallenge)
      expect(result.target).to eq(email)
    end

    it "uses the specified connection type" do
      phone = "+14155550123"
      controller.send(:generate_passwordless_otp, email: phone, connection: "sms")

      challenge = StandardId::CodeChallenge.last
      expect(challenge.channel).to eq("sms")
      expect(challenge.target).to eq(phone)
    end

    it "defaults connection to email" do
      controller.send(:generate_passwordless_otp, email: email)

      challenge = StandardId::CodeChallenge.last
      expect(challenge.channel).to eq("email")
    end

    it "raises InvalidRequestError for invalid email format" do
      expect {
        controller.send(:generate_passwordless_otp, email: "not-an-email")
      }.to raise_error(StandardId::InvalidRequestError, /Invalid email format/)
    end

    it "raises InvalidRequestError for unsupported connection type" do
      expect {
        controller.send(:generate_passwordless_otp, email: email, connection: "carrier_pigeon")
      }.to raise_error(StandardId::InvalidRequestError, /Unsupported connection type/)
    end
  end

  describe "#verify_passwordless_otp" do
    it "returns a successful result with valid code and existing account" do
      account = create_email_account(email)
      create_challenge(channel: "email", target: email)

      result = controller.send(:verify_passwordless_otp, email: email, code: otp_code)

      expect(result.success?).to be true
      expect(result.account).to eq(account)
      expect(result.challenge).to be_present
      expect(result.error).to be_nil
    end

    it "returns a failure result with invalid code" do
      create_email_account(email)
      create_challenge(channel: "email", target: email)

      result = controller.send(:verify_passwordless_otp, email: email, code: "000000")

      expect(result.success?).to be false
      expect(result.error_code).to eq(:invalid_code)
    end

    it "returns a failure result when no challenge exists" do
      create_email_account(email)

      result = controller.send(:verify_passwordless_otp, email: email, code: otp_code)

      expect(result.success?).to be false
      expect(result.error_code).to eq(:not_found)
    end

    it "defaults connection to email" do
      account = create_email_account(email)
      create_challenge(channel: "email", target: email)

      result = controller.send(:verify_passwordless_otp, email: email, code: otp_code)

      expect(result.success?).to be true
      expect(result.account).to eq(account)
    end

    it "supports SMS connection" do
      phone = "+14155550123"
      account = Account.create!(name: "Test User", email: "phone-user@example.com")
      StandardId::PhoneNumberIdentifier.create!(account: account, value: phone, verified_at: Time.current)
      create_challenge(channel: "sms", target: phone)

      result = controller.send(:verify_passwordless_otp, email: phone, code: otp_code, connection: "sms")

      expect(result.success?).to be true
      expect(result.account).to eq(account)
    end

    it "passes allow_registration option" do
      create_challenge(channel: "email", target: "new@example.com")

      result = controller.send(
        :verify_passwordless_otp,
        email: "new@example.com",
        code: otp_code,
        allow_registration: false
      )

      expect(result.success?).to be false
      expect(result.error_code).to eq(:account_not_found)
    end

    it "delegates to StandardId::Passwordless.verify" do
      mock_result = StandardId::Passwordless::VerificationService::Result.new(
        "success?": true,
        account: nil,
        challenge: nil,
        error: nil,
        error_code: nil,
        attempts: nil
      )

      expect(StandardId::Passwordless).to receive(:verify).with(
        username: email,
        code: otp_code,
        connection: "email",
        request: request,
        allow_registration: true
      ).and_return(mock_result)

      controller.send(:verify_passwordless_otp, email: email, code: otp_code)
    end
  end
end
