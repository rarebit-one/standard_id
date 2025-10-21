require "rails_helper"
require "ostruct"

RSpec.describe StandardId::Oauth::ImplicitAuthorizationFlow do
  describe "class configuration" do
    it "expects :client_id and permits implicit-specific keys plus :response_type" do
      expect(described_class.expected_params).to match_array([:client_id])
      expect(described_class.permitted_params).to include(:audience, :scope, :state, :redirect_uri, :nonce,
                                                         :connection, :prompt, :organization, :invitation, :response_type)
    end
  end

  describe "behavior" do
    let(:request) { instance_double("ActionDispatch::Request") }
    let(:account) { double("Account", id: "user_1") }

    before do
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({})
      allow(StandardId.config.oauth).to receive(:default_token_lifetime).and_return(1.hour.to_i)
    end

    def stub_client(redirects: ["https://cb.example/app", "https://cb2.example/alt"])
      client = OpenStruct.new(redirect_uris_array: redirects, primary_client_secret: OpenStruct.new)
      def client.valid_redirect_uri?(uri)
        redirect_uris_array.include?(uri)
      end
      allow(StandardId::ClientApplication).to receive_message_chain(:active, :find_by).and_return(client)
      client
    end

    it "builds redirect with access token in fragment for response_type=token" do
      stub_client
      params = {
        response_type: "token",
        client_id: "cid-1",
        scope: "read",
        state: "st",
        redirect_uri: "https://cb2.example/alt",
        audience: "https://api"
      }

      # Assert JWT encode is called for access token with expected payload
      expect(StandardId::JwtService).to receive(:encode) do |payload, opts|
        expect(payload).to include(
          sub: account.id,
          client_id: "cid-1",
          scope: "read",
          aud: "https://api"
        )
        expect(payload[:iat]).to be_a(Integer)
        expect(payload[:exp]).to be_a(Integer)
        expect(opts).to include(expires_in: 1.hour)
        "access.jwt"
      end

      flow = described_class.new(params, request, current_account: account)
      result = flow.execute

      expect(result[:status]).to eq(:found)
      expect(result[:redirect_to]).to include("https://cb2.example/alt#")
      expect(result[:redirect_to]).to include("access_token=access.jwt")
      expect(result[:redirect_to]).to include("token_type=Bearer")
      expect(result[:redirect_to]).to include("expires_in=#{1.hour.to_i}")
      expect(result[:redirect_to]).to include("scope=read")
      expect(result[:redirect_to]).to include("state=st")
    end

    it "includes id_token when response_type contains id_token" do
      stub_client
      params = {
        response_type: "token id_token",
        client_id: "cid-2",
        scope: "openid profile",
        state: "s2",
        redirect_uri: "https://cb.example/app",
        audience: "https://api",
        nonce: "n-1"
      }

      # Expect two JWTs: access token then id token
      expect(StandardId::JwtService).to receive(:encode).with(
        satisfy { |p| p[:client_id] == "cid-2" && p[:scope] == "openid profile" && p[:aud] == "https://api" && p[:sub] == account.id },
        hash_including(expires_in: 1.hour)
      ).ordered.and_return("access2.jwt")

      expect(StandardId::JwtService).to receive(:encode).with(
        satisfy { |p| p[:aud] == "cid-2" && p[:sub] == account.id && p[:nonce] == "n-1" },
        hash_including(expires_in: 1.hour)
      ).ordered.and_return("id.jwt")

      flow = described_class.new(params, request, current_account: account)
      result = flow.execute

      expect(result[:redirect_to]).to include("access_token=access2.jwt")
      expect(result[:redirect_to]).to include("id_token=id.jwt")
    end

    it "subject_id returns current_account.id" do
      stub_client
      params = { response_type: "token", client_id: "cid", redirect_uri: "https://cb.example/app" }
      flow = described_class.new(params, request, current_account: account)
      expect(flow.send(:subject_id)).to eq("user_1")
    end

    it "token_expiry is 1.hour" do
      flow = described_class.new({ response_type: "token", client_id: "c", redirect_uri: "https://cb.example/app" }, request, current_account: account)
      expect(flow.send(:token_expiry)).to eq(1.hour)
    end

    it "uses flow-specific lifetime when configured" do
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({ implicit: 15.minutes.to_i })

      stub_client
      params = {
        response_type: "token",
        client_id: "cid-implicit",
        redirect_uri: "https://cb.example/app"
      }

      expect(StandardId::JwtService).to receive(:encode).with(
        a_hash_including(client_id: "cid-implicit"),
        hash_including(expires_in: 15.minutes)
      ).once.and_return("access.jwt")

      flow = described_class.new(params, request, current_account: account)
      flow.execute
    end

    it "does not generate id_token when response_type lacks id_token" do
      stub_client
      params = { response_type: "token", client_id: "cid", redirect_uri: "https://cb.example/app" }
      flow = described_class.new(params, request, current_account: account)

      # Only one encode call for access token
      expect(StandardId::JwtService).to receive(:encode).once.and_return("access.jwt")
      result = flow.execute
      expect(result[:redirect_to]).to include("access_token=access.jwt")
      expect(result[:redirect_to]).not_to include("id_token=")
    end
  end
end
