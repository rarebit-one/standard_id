require "rails_helper"

RSpec.describe StandardId::Oauth::PasswordlessOtpFlow do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }

  before do
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil)
    allow(StandardId.config).to receive(:passwordless_sms_sender).and_return(nil)
  end

  def create_challenge(connection:, username:, code: "123456")
    StandardId::CodeChallenge.create!(
      realm: "authentication",
      channel: connection,
      target: username,
      code: code,
      expires_at: 10.minutes.from_now,
      ip_address: "127.0.0.1",
      user_agent: "RSpec"
    )
  end

  describe "authenticate!/execute" do
    it "authenticates with valid email challenge and returns token response" do
      # Pre-create account and identifier so flow doesn't need to create Account (dummy model has validations)
      account = Account.create!(name: "User", email: "user@example.com")
      StandardId::EmailIdentifier.create!(account: account, value: "user@example.com", verified_at: Time.current)

      create_challenge(connection: "email", username: "user@example.com", code: "654321")

      params = {
        grant_type: "passwordless_otp",
        client_id: "test-client",
        connection: "email",
        username: "user@example.com",
        otp: "654321"
      }

      allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

      result = described_class.new(params, request).execute

      expect(result).to include(
        access_token: "jwt-token",
        token_type: "Bearer",
        scope: "read"
      )
      # refresh token may be present; at least ensure expires_in is integer
      expect(result[:expires_in]).to be_a(Integer)

      # Identifier remains verified and linked
      identifier = StandardId::EmailIdentifier.find_by(value: "user@example.com")
      expect(identifier).to be_present
      expect(identifier.verified?).to eq(true)
      expect(identifier.account).to eq(account)
    end

    it "authenticates with valid sms challenge" do
      account = Account.create!(name: "User", email: "user@example.com")
      StandardId::PhoneNumberIdentifier.create!(account: account, value: "+14155550123", verified_at: Time.current)

      create_challenge(connection: "sms", username: "+14155550123", code: "111222")

      params = {
        grant_type: "passwordless_otp",
        client_id: "test-client",
        connection: "sms",
        username: "+14155550123",
        otp: "111222"
      }

      allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

      result = described_class.new(params, request).execute
      expect(result[:access_token]).to eq("jwt-token")

      phone = StandardId::PhoneNumberIdentifier.find_by(value: "+14155550123")
      expect(phone).to be_present
      expect(phone.verified?).to eq(true)
    end

    it "rejects invalid or expired code" do
      # Create a challenge but use wrong code
      create_challenge(connection: "email", username: "user@example.com", code: "999000")

      params = {
        grant_type: "passwordless_otp",
        client_id: "test-client",
        connection: "email",
        username: "user@example.com",
        otp: "000999"
      }

      flow = described_class.new(params, request)
      expect { flow.execute }.to raise_error(StandardId::InvalidGrantError, /Invalid or expired/)
    end

    it "validates scope tokens" do
      account = Account.create!(name: "User", email: "user@example.com")
      StandardId::EmailIdentifier.create!(account: account, value: "user@example.com", verified_at: Time.current)
      create_challenge(connection: "email", username: "user@example.com", code: "123123")

      params = {
        grant_type: "passwordless_otp",
        client_id: "test-client",
        connection: "email",
        username: "user@example.com",
        otp: "123123",
        scope: "read write!" # invalid token '!'
      }

      flow = described_class.new(params, request)
      expect { flow.execute }.to raise_error(StandardId::InvalidScopeError)
    end
  end

  describe "custom scope claims" do
    it "passes the resolved account and client to the claim resolver" do
      allow(StandardId.config.oauth).to receive(:scope_claims).and_return({ "read" => [:channel_id] })
      allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({
        channel_id: ->(client:, account:, request:) {
          "#{client.object_id}-#{account.id}-#{request.object_id}"
        }
      })

      account = instance_double("Account", id: 55)
      allow(account).to receive(:blank?).and_return(false)
      code_challenge = instance_double("StandardId::CodeChallenge", use!: true)
      allow(code_challenge).to receive(:blank?).and_return(false)
      client_application = instance_double("StandardId::ClientApplication")
      flow = described_class.new(
        {
          grant_type: "passwordless_otp",
          client_id: "client-123",
          connection: "email",
          username: "user@example.com",
          otp: "999000"
        },
        request
      )

      allow(flow).to receive(:code_challenge).and_return(code_challenge)
      allow(flow).to receive(:account).and_return(account)
      allow(StandardId::ClientApplication).to receive(:find_by).and_return(client_application)

      encoded_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        encoded_payloads << payload
        "jwt-token"
      end

      strategy = instance_double("StandardId::Passwordless::EmailStrategy", find_or_create_account: account)
      allow(flow).to receive(:strategy_for).and_return(strategy)

      result = flow.execute
      expect(result[:access_token]).to eq("jwt-token")
      expect(encoded_payloads.first[:channel_id]).to eq("#{client_application.object_id}-#{account.id}-#{request.object_id}")
    end
  end
end
