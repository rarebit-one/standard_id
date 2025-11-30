require "rails_helper"

RSpec.describe StandardId::Oauth::ClientCredentialsFlow do
  let(:request) { instance_double("ActionDispatch::Request") }
  let(:client_id) { "client_123" }
  let(:client_secret) { "s3cr3t" }
  let(:audience) { "https://api.example.com" }
  let(:params) { { client_id: client_id, client_secret: client_secret, audience: audience } }

  let(:client_application) { double("ClientApplication") }
  let(:credential) do
    double(
      account_id: 42,
      client_id: client_id,
      scopes: "read write",
      authenticate_client_secret: true,
      client_application: client_application
    )
  end

  describe "#authenticate!" do
    it "authenticates with valid client credentials" do
      allow_any_instance_of(StandardId::Oauth::ClientCredentialsFlow)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(credential)

      flow = described_class.new(params, request)
      expect { flow.authenticate! }.not_to raise_error
    end

    it "raises InvalidClientError when credentials are invalid" do
      allow_any_instance_of(StandardId::Oauth::ClientCredentialsFlow)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_raise(StandardId::InvalidClientError)

      flow = described_class.new(params, request)
      expect { flow.authenticate! }.to raise_error(StandardId::InvalidClientError)
    end
  end

  describe "private accessors" do
    let(:flow) { described_class.new(params, request) }

    before do
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({})
      allow(StandardId.config.oauth).to receive(:default_token_lifetime).and_return(1.hour.to_i)

      allow_any_instance_of(StandardId::Oauth::ClientCredentialsFlow)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(credential)

      flow.authenticate!
    end

    it "exposes subject_id, client_id, token_scope, grant_type, audience, token_expiry after auth" do
      expect(flow.send(:subject_id)).to eq(client_id)
      expect(flow.send(:client_id)).to eq(client_id)
      expect(flow.send(:token_scope)).to eq("read write")
      expect(flow.send(:grant_type)).to eq("client_credentials")
      expect(flow.send(:audience)).to eq(audience)
      expect(flow.send(:token_expiry)).to eq(1.hour)
    end

    it "uses flow-specific lifetime when configured" do
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({ client_credentials: 30.minutes.to_i })

      flow.authenticate!

      expect(flow.send(:token_expiry)).to eq(30.minutes)
    end
  end

  describe "custom scope claims" do
    let(:client_application) { instance_double("StandardId::ClientApplication", owner_id: "channel-42") }
    let(:credential) do
      double(
        client_id: client_id,
        scopes: "inventory.write",
        client_application: client_application
      )
    end

    before do
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({})
      allow(StandardId.config.oauth).to receive(:default_token_lifetime).and_return(1.hour.to_i)

      allow_any_instance_of(described_class)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(credential)
    end

    it "passes client context to the claim resolver" do
      allow(StandardId.config.oauth).to receive(:scope_claims).and_return({ "inventory.write" => [:channel_id] })
      allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({ channel_id: ->(client:) { client.owner_id } })

      expect(StandardId::JwtService).to receive(:encode) do |payload, _|
        expect(payload[:channel_id]).to eq("channel-42")
        "jwt-token"
      end

      result = described_class.new(params, request).execute
      expect(result[:access_token]).to eq("jwt-token")
    end
  end
end
