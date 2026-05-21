require "rails_helper"

RSpec.describe StandardId::Oauth::RefreshTokenFlow do
  let(:request) { instance_double("ActionDispatch::Request") }
  let(:client_id) { "client_123" }
  let(:scope) { "read write" }
  let(:account) { Account.create!(name: "Test User", email: "refresh-flow@example.com") }
  let(:sub) { account.id }
  let(:jti) { SecureRandom.uuid }
  let(:refresh_payload) { { sub: sub, client_id: client_id, scope: scope, jti: jti } }

  def create_refresh_token_record(attrs = {})
    StandardId::RefreshToken.create!({
      account: account,
      token_digest: StandardId::RefreshToken.digest_for(jti),
      expires_at: 30.days.from_now
    }.merge(attrs))
  end

  describe "#authenticate!" do
    it "authenticates with valid refresh token and matching DB record" do
      create_refresh_token_record
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.not_to raise_error
    end

    it "authenticates with valid refresh token and optional client_secret" do
      create_refresh_token_record
      flow_with_secret = described_class.new({ client_id: client_id, refresh_token: "rtok", client_secret: "sec" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)
      allow(flow_with_secret).to receive(:validate_client_secret!)
        .with(client_id, "sec")
        .and_return(true)

      expect { flow_with_secret.authenticate! }.not_to raise_error
      expect(flow_with_secret).to have_received(:validate_client_secret!).with(client_id, "sec")
    end

    it "raises InvalidGrantError when refresh token is invalid or expired" do
      flow = described_class.new({ client_id: client_id, refresh_token: "bad" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("bad").and_return(nil)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError)
    end

    it "raises InvalidGrantError when refresh token client_id mismatches" do
      create_refresh_token_record
      payload = refresh_payload.merge(client_id: "other")
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(payload)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError)
    end

    it "allows scope narrowing when requested scope is subset" do
      create_refresh_token_record
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok", scope: "read" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.not_to raise_error
      expect(flow.send(:token_scope)).to eq("read")
    end

    it "raises InvalidScopeError when requested scope exceeds original" do
      create_refresh_token_record
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok", scope: "admin" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidScopeError)
    end

    it "raises InvalidScopeError for invalid requested scope tokens" do
      create_refresh_token_record
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok", scope: "read invalid@token" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidScopeError)
    end

    context "with legacy tokens (no jti)" do
      let(:legacy_payload) { { sub: sub, client_id: client_id, scope: scope } }

      it "gracefully authenticates tokens without jti" do
        flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
        allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(legacy_payload)

        expect { flow.authenticate! }.not_to raise_error
      end
    end
  end

  describe "database-backed token validation" do
    it "raises InvalidGrantError when token record is not found in database" do
      # No DB record created
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError, /not found/)
    end

    it "revokes the current token during rotation (execute)" do
      record = create_refresh_token_record
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      flow.execute
      expect(record.reload.revoked?).to be true
    end

    it "raises InvalidGrantError and revokes family when a revoked token is reused" do
      root = create_refresh_token_record
      child_jti = SecureRandom.uuid
      child = StandardId::RefreshToken.create!(
        account: account,
        token_digest: StandardId::RefreshToken.digest_for(child_jti),
        expires_at: 30.days.from_now,
        previous_token: root
      )

      # Revoke the root (simulating it was already rotated)
      root.revoke!

      # Attempt to reuse the root token
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError, /reuse detected/)

      # Both tokens in the family should be revoked
      expect(root.reload.revoked?).to be true
      expect(child.reload.revoked?).to be true
    end

    it "raises InvalidGrantError for expired token records" do
      create_refresh_token_record(expires_at: 1.hour.ago)
      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError, /no longer valid/)
    end
  end

  describe "private API after authenticate!" do
    let(:params) { { client_id: client_id, refresh_token: "rtok" } }
    let(:flow) { described_class.new(params, request) }

    before do
      create_refresh_token_record
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

    it "generate_refresh_token issues a JWT with expected payload including jti" do
      expect(StandardId::JwtService).to receive(:encode) do |payload, opts|
        expect(payload).to include(
          sub: sub,
          client_id: client_id,
          scope: scope,
          grant_type: "refresh_token"
        )
        expect(payload[:jti]).to be_present
        expect(opts[:expires_at]).to be_within(2.seconds).of(30.days.from_now)
        "new-rtok"
      end

      token = flow.send(:generate_refresh_token)
      expect(token).to eq("new-rtok")
    end

    it "creates a new RefreshToken record when generating a refresh token" do
      allow(StandardId::JwtService).to receive(:encode).and_return("new-rtok")

      expect {
        flow.send(:generate_refresh_token)
      }.to change(StandardId::RefreshToken, :count).by(1)

      new_record = StandardId::RefreshToken.last
      expect(new_record.account_id).to eq(sub)
      expect(new_record.previous_token).to be_present
    end
  end

  describe "custom scope claims" do
    let(:resolver) { double("SessionResolver") }

    it "passes account and client context to the resolver" do
      create_refresh_token_record
      client_application = instance_double("StandardId::ClientApplication")

      allow(StandardId).to receive(:account_class).and_return(Account)
      allow(StandardId::ClientApplication).to receive(:find_by).with(client_id: client_id).and_return(client_application)

      allow(StandardId.config.oauth).to receive(:scope_claims).and_return({ "read" => [:session_id] })
      allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({ session_id: resolver })

      # `profile` is passed through when the resolver's signature does not
      # filter it out (e.g., when introspection isn't available, as with
      # mocked resolvers). It is nil here because the audience has no
      # `audience_profile_types` binding configured.
      expect(resolver).to receive(:call).with(
        client: client_application,
        account: account,
        request: request,
        audience: nil,
        profile: nil
      ).and_return("session-123")

      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload.merge(scope: "read"))

      encoded_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        encoded_payloads << payload
        "jwt-token"
      end

      result = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request).execute
      expect(result[:access_token]).to eq("jwt-token")
      expect(encoded_payloads.first[:session_id]).to eq("session-123")
    end
  end

  describe "audience persistence" do
    let(:audience) { "companion_kit" }
    let(:refresh_payload_with_aud) { refresh_payload.merge(aud: audience) }

    before { create_refresh_token_record }

    it "uses stored audience from refresh token" do
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload_with_aud)

      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      flow.authenticate!

      expect(flow.send(:audience)).to eq(audience)
    end

    it "includes stored audience in new access token" do
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload_with_aud)

      encoded_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        encoded_payloads << payload
        "jwt-token"
      end

      described_class.new({ client_id: client_id, refresh_token: "rtok" }, request).execute

      # First payload is the access token
      expect(encoded_payloads.first[:aud]).to eq(audience)
    end

    it "includes stored audience in new refresh token" do
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload_with_aud)

      all_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        all_payloads << payload
        "jwt-token"
      end

      described_class.new({ client_id: client_id, refresh_token: "rtok" }, request).execute

      # Last payload is the new refresh token
      expect(all_payloads.last[:aud]).to eq(audience)
    end

    it "ignores audience param passed on refresh request (cannot change audience)" do
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload_with_aud)

      flow = described_class.new({
        client_id: client_id,
        refresh_token: "rtok",
        audience: "different_audience"  # Should be ignored
      }, request)
      flow.authenticate!

      expect(flow.send(:audience)).to eq(audience)  # Uses stored, not requested
    end

    it "returns nil audience when refresh token has no audience" do
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      flow.authenticate!

      expect(flow.send(:audience)).to be_nil
    end
  end

  describe "reuse detection event" do
    it "publishes OAUTH_REFRESH_TOKEN_REUSE_DETECTED event on token reuse" do
      record = create_refresh_token_record
      record.revoke! # Simulate already-rotated token

      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)

      expect(StandardId::Events).to receive(:publish).with(
        StandardId::Events::OAUTH_REFRESH_TOKEN_REUSE_DETECTED,
        account_id: sub,
        client_id: client_id,
        refresh_token_id: record.id
      )

      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError, /reuse detected/)
    end
  end

  describe "session binding" do
    let(:session) do
      StandardId::BrowserSession.create!(
        account: account,
        user_agent: "Chrome/91.0",
        expires_at: 1.hour.from_now
      )
    end

    it "preserves session_id when rotating refresh tokens" do
      record = create_refresh_token_record(session: session)

      allow(StandardId::JwtService).to receive(:decode).with("rtok").and_return(refresh_payload)
      allow(StandardId::JwtService).to receive(:encode).and_return("new-jwt")

      flow = described_class.new({ client_id: client_id, refresh_token: "rtok" }, request)
      flow.authenticate!
      flow.send(:generate_refresh_token)

      new_record = StandardId::RefreshToken.where(previous_token: record).first
      expect(new_record.session_id).to eq(session.id)
    end
  end
end
