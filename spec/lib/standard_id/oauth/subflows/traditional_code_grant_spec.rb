require "rails_helper"

RSpec.describe StandardId::Oauth::Subflows::TraditionalCodeGrant do
  let(:account) { Account.create!(name: "User", email: "user@example.com") }
  let(:params) do
    {
      client_id: "client_123",
      redirect_uri: "https://app.example.com/callback",
      scope: "openid profile",
      audience: "api://default",
      state: "random_state",
      code_challenge: "challenge123",
      code_challenge_method: "S256",
      current_account: account
    }
  end

  subject { described_class.new(**params) }

  describe "#call" do
    it "stores authorization code and returns redirect response" do
      expect(StandardId::AuthorizationCode).to receive(:issue!).with(
        hash_including(
          client_id: "client_123",
          redirect_uri: "https://app.example.com/callback",
          scope: "openid profile",
          audience: "api://default",
          account: account,
          code_challenge: "challenge123",
          code_challenge_method: "S256",
          nonce: nil,
          metadata: { state: "random_state" }
        )
      )

      result = subject.call

      expect(result[:status]).to eq(:found)
      expect(result[:redirect_to]).to include("https://app.example.com/callback")
      expect(result[:redirect_to]).to include("code=")
      expect(result[:redirect_to]).to include("state=random_state")
    end

    it "forwards nonce to AuthorizationCode.issue!" do
      params[:nonce] = "test-nonce-123"
      subject = described_class.new(**params)

      expect(StandardId::AuthorizationCode).to receive(:issue!).with(
        hash_including(nonce: "test-nonce-123")
      )

      subject.call
    end

    it "handles missing state gracefully" do
      params.delete(:state)
      subject = described_class.new(**params)

      expect(StandardId::AuthorizationCode).to receive(:issue!).with(
        hash_including(metadata: {})
      )

      result = subject.call
      expect(result[:redirect_to]).not_to include("state=")
    end

    it "preserves existing query parameters in redirect URI" do
      params[:redirect_uri] = "https://app.example.com/callback?existing=param"
      subject = described_class.new(**params)

      allow(StandardId::AuthorizationCode).to receive(:issue!)

      result = subject.call
      expect(result[:redirect_to]).to include("existing=param")
      expect(result[:redirect_to]).to include("code=")
    end
  end
end
