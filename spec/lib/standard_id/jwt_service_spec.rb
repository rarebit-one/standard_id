require "rails_helper"

RSpec.describe StandardId::JwtService do
  describe ".decode_session" do
    let(:payload) do
      {
        sub: "account-123",
        client_id: "client-456",
        scope: "openid profile",
        grant_type: "password",
        aud: "https://example.com",
        custom_flag: true,
        metadata: { "plan" => "pro" }
      }
    end

    before do
      allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({})
    end

    it "returns custom_claims with non-reserved payload keys" do
      token = described_class.encode(payload, expires_in: 5.minutes)

      session = described_class.decode_session(token)

      expect(session.scopes).to eq(%w[openid profile])
      expect(session).not_to respond_to(:custom_flag)
      expect(session).not_to respond_to(:metadata)
    end

    context "when claim resolvers are configured" do
      before do
        reset_jwt_session_class!

        allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({
          custom_flag: ->(**) { },
          metadata: ->(**) { },
          other_claims: ->(**) { }
        })
      end

      it "exposes direct accessors for configured claim keys" do
        token = described_class.encode(payload, expires_in: 5.minutes)

        session = described_class.decode_session(token)

        expect(session.custom_flag).to eq(true)
        expect(session.metadata).to eq({ "plan" => "pro" })
        expect(session.other_claims).to be_nil
      end
    end
  end
end
