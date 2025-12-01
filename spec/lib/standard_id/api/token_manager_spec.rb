require "rails_helper"

RSpec.describe StandardId::Api::TokenManager, type: :model do
  let(:request) do
    instance_double(
      ActionDispatch::Request,
      headers: {},
      remote_ip: "192.168.1.100",
      user_agent: "TestApp/1.0",
      ssl?: false
    )
  end
  let(:token_manager) { StandardId::Api::TokenManager.new(request) }
  let(:account) { Account.create!(name: "Test Service", email: "service@example.com") }

  describe "#bearer_token" do
    context "when Authorization header is present with Bearer token" do
      it "extracts the token" do
        allow(request).to receive(:headers).and_return({
          'Authorization' => 'Bearer abc123token'
        })

        result = token_manager.bearer_token
        expect(result).to eq('abc123token')
      end

      it "handles tokens with spaces and special characters" do
        allow(request).to receive(:headers).and_return({
          'Authorization' => 'Bearer token_with-special.chars'
        })

        result = token_manager.bearer_token
        expect(result).to eq('token_with-special.chars')
      end
    end

    context "when Authorization header is missing" do
      it "returns nil" do
        allow(request).to receive(:headers).and_return({})

        result = token_manager.bearer_token
        expect(result).to be_nil
      end
    end

    context "when Authorization header doesn't start with Bearer" do
      it "returns nil for Basic auth" do
        allow(request).to receive(:headers).and_return({
          'Authorization' => 'Basic dXNlcjpwYXNz'
        })

        result = token_manager.bearer_token
        expect(result).to be_nil
      end

      it "returns nil for malformed header" do
        allow(request).to receive(:headers).and_return({
          'Authorization' => 'InvalidFormat'
        })

        result = token_manager.bearer_token
        expect(result).to be_nil
      end
    end

    context "when Authorization header is empty" do
      it "returns nil" do
        allow(request).to receive(:headers).and_return({
          'Authorization' => ''
        })

        result = token_manager.bearer_token
        expect(result).to be_nil
      end
    end
  end

  describe "#generate_lookup_hash" do
    it "generates a consistent SHA256 hash" do
      token = "test_token_123"

      result1 = token_manager.generate_lookup_hash(token)
      result2 = token_manager.generate_lookup_hash(token)

      expect(result1).to eq(result2)
      expect(result1).to be_a(String)
      expect(result1.length).to eq(64) # SHA256 hex string length
    end

    it "generates different hashes for different tokens" do
      token1 = "token_one"
      token2 = "token_two"

      hash1 = token_manager.generate_lookup_hash(token1)
      hash2 = token_manager.generate_lookup_hash(token2)

      expect(hash1).not_to eq(hash2)
    end

    it "includes Rails secret key base in hash generation" do
      token = "test_token"
      expected_hash = Digest::SHA256.hexdigest("#{token}:#{Rails.application.secret_key_base}")

      result = token_manager.generate_lookup_hash(token)

      expect(result).to eq(expected_hash)
    end
  end

  describe "#create_device_session" do
    it "creates a device session with default values" do
      session = token_manager.create_device_session(account)

      expect(session).to be_a(StandardId::DeviceSession)
      expect(session.account).to eq(account)
      expect(session.ip_address).to eq("192.168.1.100")
      expect(session.device_agent).to eq("TestApp/1.0")
      expect(session.device_id).to be_present
      expect(session.expires_at).to be_within(1.minute).of(StandardId::DeviceSession.expiry)
      expect(session).to be_persisted
    end

    it "creates a device session with custom device_id and device_agent" do
      custom_device_id = "custom-device-123"
      custom_agent = "CustomApp/2.0"

      session = token_manager.create_device_session(
        account,
        device_id: custom_device_id,
        device_agent: custom_agent
      )

      expect(session.device_id).to eq(custom_device_id)
      expect(session.device_agent).to eq(custom_agent)
    end

    it "generates a UUID when device_id is nil" do
      session = token_manager.create_device_session(account, device_id: nil)

      expect(session.device_id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it "uses request user_agent when device_agent is nil" do
      session = token_manager.create_device_session(account, device_agent: nil)

      expect(session.device_agent).to eq("TestApp/1.0")
    end
  end

  describe "#create_service_session" do
    it "creates a service session with required parameters" do
      session = token_manager.create_service_session(
        account,
        service_name: "payment-processor",
        service_version: "1.2.3",
        owner: account
      )

      expect(session).to be_a(StandardId::ServiceSession)
      expect(session.account).to eq(account)
      expect(session.service_name).to eq("payment-processor")
      expect(session.service_version).to eq("1.2.3")
      expect(session.ip_address).to eq("192.168.1.100")
      expect(session.metadata).to eq({})
      expect(session.owner).to eq(account)
      expect(session.expires_at).to be_within(1.minute).of(StandardId::ServiceSession.default_expiry)
      expect(session).to be_persisted
    end

    it "creates a service session with owner and metadata" do
      owner = account
      metadata = { region: "us-east-1", pod: "pod-7" }

      session = token_manager.create_service_session(
        account,
        service_name: "analytics",
        service_version: "2.1.0",
        owner: owner,
        metadata: metadata
      )

      expect(session.owner).to eq(owner)
      expect(session.metadata).to eq(metadata.stringify_keys)
    end

    it "handles empty metadata hash" do
      session = token_manager.create_service_session(
        account,
        service_name: "analytics",
        service_version: "2.1.0",
        owner: account,
        metadata: {}
      )

      expect(session.metadata).to eq({})
    end

    it "handles nil metadata by using default empty hash" do
      session = token_manager.create_service_session(
        account,
        service_name: "data-service",
        service_version: "1.5.0",
        owner: account,
        metadata: nil
      )

      expect(session.metadata).to eq({})
    end
  end

  describe "integration with session models" do
    it "creates sessions that can be found by their tokens" do
      device_session = token_manager.create_device_session(account)
      service_session = token_manager.create_service_session(
        account,
        service_name: "analytics",
        service_version: "1.0.0",
        owner: account
      )

      # Test device session lookup
      device_lookup_hash = token_manager.generate_lookup_hash(device_session.token)
      found_device = StandardId::DeviceSession.find_by(lookup_hash: device_lookup_hash)
      expect(found_device).to eq(device_session)

      # Test service session lookup
      service_lookup_hash = token_manager.generate_lookup_hash(service_session.token)
      found_service = StandardId::ServiceSession.find_by(lookup_hash: service_lookup_hash)
      expect(found_service).to eq(service_session)
    end
  end
end
