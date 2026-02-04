require "rails_helper"

RSpec.describe StandardId::Oauth::AuthorizationCodeFlow do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }
  let(:client_id) { "client_123" }
  let(:client_secret) { "s3cr3t" }
  let(:code) { "auth_code_abc" }
  let(:redirect_uri) { "https://app.example.com/callback" }
  let(:params) { { client_id: client_id, client_secret: client_secret, code: code, redirect_uri: redirect_uri } }

  let(:account) { instance_double("Account", id: 99) }

  let(:credential) do
    double(
      client_id: client_id
    )
  end

  let(:authorization_code) do
    instance_double(
      "AuthorizationCode",
      valid_for_client?: true,
      redirect_uri: redirect_uri,
      account_id: 99,
      account: account,
      scope: "read write",
      audience: nil
    ).tap do |ac|
      allow(ac).to receive(:mark_as_used!)
      allow(ac).to receive(:pkce_valid?).and_return(true)
    end
  end

  describe "#authenticate!" do
    it "authenticates with valid client/secret and authorization code, and marks the code as used" do
      allow_any_instance_of(described_class)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(credential)

      allow_any_instance_of(described_class)
        .to receive(:find_authorization_code)
        .with(code)
        .and_return(authorization_code)

      flow = described_class.new(params, request)
      expect { flow.authenticate! }.not_to raise_error
      expect(authorization_code).to have_received(:mark_as_used!)
    end

    it "raises InvalidGrantError when authorization code is missing/invalid" do
      allow_any_instance_of(described_class)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(credential)

      allow_any_instance_of(described_class)
        .to receive(:find_authorization_code)
        .with(code)
        .and_return(nil)

      flow = described_class.new(params, request)
      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError)
    end

    it "raises InvalidGrantError when code is not valid for client" do
      bad_code = instance_double(
        "AuthorizationCode",
        valid_for_client?: false,
        redirect_uri: redirect_uri
      )

      allow_any_instance_of(described_class)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(credential)

      allow_any_instance_of(described_class)
        .to receive(:find_authorization_code)
        .with(code)
        .and_return(bad_code)

      flow = described_class.new(params, request)
      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError)
    end

    it "raises InvalidGrantError on redirect URI mismatch" do
      allow_any_instance_of(described_class)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(credential)

      allow_any_instance_of(described_class)
        .to receive(:find_authorization_code)
        .with(code)
        .and_return(authorization_code)

      mismatched_params = params.merge(redirect_uri: "https://app.example.com/other")

      flow = described_class.new(mismatched_params, request)
      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError)
    end
  end

  describe "private API" do
    let(:flow) { described_class.new(params, request) }

    before do
      allow_any_instance_of(described_class)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(credential)

      allow_any_instance_of(described_class)
        .to receive(:find_authorization_code)
        .with(code)
        .and_return(authorization_code)

      flow.authenticate!
    end

    it "exposes subject_id, client_id, token_scope, grant_type and refresh support" do
      expect(flow.send(:subject_id)).to eq(99)
      expect(flow.send(:client_id)).to eq(client_id)
      expect(flow.send(:token_scope)).to eq("read write")
      expect(flow.send(:grant_type)).to eq("authorization_code")
      expect(flow.send(:supports_refresh_token?)).to be(true)

      token = flow.send(:generate_refresh_token)
      expect(token).to be_a(String)
      expect(token.length).to be > 0
    end

    it "finds authorization code using StandardId::AuthorizationCode.lookup" do
      code = "test_code_123"
      auth_code = instance_double("StandardId::AuthorizationCode")
      test_flow = described_class.new(params, request)

      # Override the stub from before block to allow any arguments
      allow(test_flow).to receive(:find_authorization_code).and_call_original
      expect(StandardId::AuthorizationCode).to receive(:lookup).with(code).and_return(auth_code)

      result = test_flow.send(:find_authorization_code, code)
      expect(result).to eq(auth_code)
    end

    it "returns nil when authorization code is not found" do
      code = "nonexistent_code"
      test_flow = described_class.new(params, request)

      # Override the stub from before block to allow any arguments
      allow(test_flow).to receive(:find_authorization_code).and_call_original
      expect(StandardId::AuthorizationCode).to receive(:lookup).with(code).and_return(nil)

      result = test_flow.send(:find_authorization_code, code)
      expect(result).to be_nil
    end
  end

  describe "custom scope claims" do
    let(:account) { instance_double("Account", id: 99, inactive?: false, locked?: false) }
    let(:client_application) { instance_double("StandardId::ClientApplication") }
    let(:credential_with_app) do
      instance_double(
        "StandardId::ClientSecretCredential",
        client_id: client_id,
        client_application: client_application
      )
    end

    it "passes client and account context to the resolver" do
      scoped_code = instance_double(
        "AuthorizationCode",
        valid_for_client?: true,
        redirect_uri: redirect_uri,
        account_id: account.id,
        account: account,
        scope: "profile",
        audience: nil
      )
      allow(scoped_code).to receive(:mark_as_used!)
      allow(scoped_code).to receive(:pkce_valid?).and_return(true)

      allow(StandardId.config.oauth).to receive(:scope_claims).and_return({ "profile" => [:profile_id] })
      allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({
        profile_id: ->(client:, account:, request:) {
          "#{client.object_id}-#{account.id}-#{request.object_id}"
        }
      })

      allow_any_instance_of(described_class)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(credential_with_app)

      allow_any_instance_of(described_class)
        .to receive(:find_authorization_code)
        .with(code)
        .and_return(scoped_code)

      encoded_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        encoded_payloads << payload
        "jwt-token"
      end

      result = described_class.new(params, request).execute
      expect(result[:access_token]).to eq("jwt-token")
      expect(encoded_payloads.first[:profile_id]).to eq("#{client_application.object_id}-#{account.id}-#{request.object_id}")
    end
  end
end
