require "rails_helper"

RSpec.describe StandardId::Oauth::SocialFlow do
  let(:params) { { grant_type: "social" } }
  let(:request) { instance_double(ActionDispatch::Request, params: params) }
  let(:account) { instance_double("Account", id: 123, locked?: false, inactive?: false) }
  let(:connection) { "google" }
  let(:scopes) { nil }

  subject do
    described_class.new(
      params,
      request,
      account: account,
      connection: connection,
      scopes: scopes
    )
  end

  before do
    allow(StandardId).to receive(:account_class).and_return(double(find_by: account))
    allow(StandardId::JwtService).to receive(:encode).and_return("jwt_token")
  end

  describe "#initialize" do
    context "when available_scopes is not configured" do
      before do
        StandardId.config.social.available_scopes = []
      end

      it "accepts any scope without validation" do
        flow = described_class.new(
          params,
          request,
          account: account,
          connection: connection,
          scopes: "profile email custom_scope"
        )

        expect(flow.scopes).to eq("profile email custom_scope")
      end
    end

    context "when available_scopes is configured" do
      before do
        StandardId.config.social.available_scopes = ["profile", "email", "offline_access"]
      end

      it "accepts valid scopes" do
        flow = described_class.new(
          params,
          request,
          account: account,
          connection: connection,
          scopes: "profile email"
        )

        expect(flow.scopes).to eq("profile email")
      end

      it "normalizes scope string by removing duplicates" do
        flow = described_class.new(
          params,
          request,
          account: account,
          connection: connection,
          scopes: "profile email profile"
        )

        expect(flow.scopes).to eq("profile email")
      end

      it "raises InvalidScopeError for invalid scopes" do
        expect {
          described_class.new(
            params,
            request,
            account: account,
            connection: connection,
            scopes: "profile invalid_scope"
          )
        }.to raise_error(
          StandardId::InvalidScopeError,
          /Invalid scope\(s\): invalid_scope/
        )
      end

      it "raises InvalidScopeError with multiple invalid scopes" do
        expect {
          described_class.new(
            params,
            request,
            account: account,
            connection: connection,
            scopes: "invalid1 invalid2 profile"
          )
        }.to raise_error(
          StandardId::InvalidScopeError,
          /Invalid scope\(s\): invalid1, invalid2/
        )
      end

      it "accepts nil scopes" do
        flow = described_class.new(
          params,
          request,
          account: account,
          connection: connection,
          scopes: nil
        )

        expect(flow.scopes).to be_nil
      end

      it "accepts empty string scopes" do
        flow = described_class.new(
          params,
          request,
          account: account,
          connection: connection,
          scopes: ""
        )

        expect(flow.scopes).to be_nil
      end
    end
  end

  describe "#execute" do
    before do
      StandardId.config.social.available_scopes = ["profile", "email"]
      StandardId.config.oauth.scope_claims = {}
      StandardId.config.oauth.claim_resolvers = {}
    end

    let(:scopes) { "profile email" }

    it "generates token response with scopes" do
      response = subject.execute

      expect(response).to include(
        access_token: "jwt_token",
        token_type: "Bearer",
        scope: "profile email"
      )
    end

    it "includes refresh_token in response" do
      response = subject.execute

      expect(response).to have_key(:refresh_token)
    end

    it "includes provider in JWT payload" do
      expect(StandardId::JwtService).to receive(:encode).with(
        hash_including(provider: "google"),
        anything
      ).and_return("jwt_token")

      subject.execute
    end

    it "includes client_id in JWT payload" do
      expect(StandardId::JwtService).to receive(:encode).with(
        hash_including(client_id: "google"),
        anything
      ).and_return("jwt_token")

      subject.execute
    end
  end

  describe "#token_scope" do
    let(:scopes) { "profile email" }

    it "returns the validated scopes" do
      expect(subject.send(:token_scope)).to eq("profile email")
    end
  end

  describe "#grant_type" do
    it "returns 'social'" do
      expect(subject.send(:grant_type)).to eq("social")
    end
  end

  describe "#supports_refresh_token?" do
    it "returns true" do
      expect(subject.send(:supports_refresh_token?)).to be true
    end
  end

  describe "claim_resolvers context" do
    before do
      StandardId.config.social.available_scopes = ["profile"]
      StandardId.config.oauth.scope_claims = { "profile" => ["profile_id"] }
      StandardId.config.oauth.claim_resolvers = {
        "profile_id" => ->(account:, request:) {
          "#{account.id}_#{request.params[:profile_type]}"
        }
      }
    end

    let(:scopes) { "profile" }
    let(:params) { { grant_type: "social", profile_type: "business" } }

    it "passes request context to claim_resolvers" do
      allow(request).to receive(:params).and_return(params)

      expect(StandardId::JwtService).to receive(:encode).with(
        hash_including(profile_id: "123_business"),
        anything
      ).and_return("jwt_token")

      subject.execute
    end
  end
end
