require "rails_helper"

RSpec.describe StandardId::Oauth::RefreshTokenFlow do
  let(:request) { instance_double("ActionDispatch::Request") }
  let(:client_id) { "client_123" }
  let(:scope) { "read write" }
  let(:sub) { 42 }
  let(:refresh_payload) { { sub: sub, client_id: client_id, scope: scope } }

  describe "#authenticate!" do
    it "authenticates with valid refresh token and optional client_secret" do
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)

      allow(StandardId::JwtService)
        .to receive(:decode)
        .with("rtok")
        .and_return(refresh_payload)

      # When client_secret is provided, ensure client validation is called
      flow_with_secret = described_class.new({ client_id: client_id, refresh_token: "rtok", client_secret: "sec" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)
      expect_any_instance_of(described_class)
        .to receive(:validate_client_secret!)
        .with(client_id, "sec")
        .and_return(true)

      expect { flow.authenticate! }.not_to raise_error
      expect { flow_with_secret.authenticate! }.not_to raise_error
    end

    it "raises InvalidGrantError when refresh token is invalid or expired" do
      flow = described_class.new({ client_id: client_id, refresh_token: "bad" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("bad").and_return(nil)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError)
    end

    it "raises InvalidGrantError when refresh token client_id mismatches" do
      payload = refresh_payload.merge(client_id: "other")
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(payload)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError)
    end

    it "allows scope narrowing when requested scope is subset" do
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok", scope: "read" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.not_to raise_error
      expect(flow.send(:token_scope)).to eq("read")
    end

    it "raises InvalidScopeError when requested scope exceeds original" do
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok", scope: "admin" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidScopeError)
    end

    it "raises InvalidScopeError for invalid requested scope tokens" do
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok", scope: "read invalid@token" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidScopeError)
    end
  end

  describe "private API after authenticate!" do
    let(:params) { { client_id: client_id, refresh_token: "rtok" } }
    let(:flow) { described_class.new(params, request) }

    before do
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)
      flow.authenticate!
    end

    it "exposes subject_id, client_id, token_scope (from payload), grant_type and supports refresh" do
      expect(flow.send(:subject_id)).to eq(sub)
      expect(flow.send(:client_id)).to eq(client_id)
      expect(flow.send(:token_scope)).to eq(scope)
      expect(flow.send(:grant_type)).to eq("refresh_token")
      expect(flow.send(:supports_refresh_token?)).to be(true)
    end

    it "generate_refresh_token issues a JWT with expected payload" do
      expect(StandardId::JwtService).to receive(:encode) do |payload, opts|
        expect(payload).to include(
          sub: sub,
          client_id: client_id,
          scope: scope,
          grant_type: "refresh_token"
        )
        expect(opts).to include(expires_in: 30.days)
        "new-rtok"
      end

      token = flow.send(:generate_refresh_token)
      expect(token).to eq("new-rtok")
    end
  end
end
