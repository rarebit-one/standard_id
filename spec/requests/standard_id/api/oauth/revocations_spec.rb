require "rails_helper"

RSpec.describe "StandardId::Api::Oauth::RevocationsController", type: :request do
  let(:account) { Account.create!(name: "Test User", email: "revoke-#{SecureRandom.hex(4)}@example.com") }

  describe "POST /api/oauth/revoke" do
    context "with a valid token and active device sessions" do
      let!(:device_session) do
        StandardId::DeviceSession.create!(
          account: account,
          device_id: "device-#{SecureRandom.hex(4)}",
          device_agent: "MyApp/1.0 (iPhone; iOS 14.6)",
          expires_at: 2.weeks.from_now
        )
      end

      let(:token) do
        StandardId::JwtService.encode({ sub: account.id, client_id: "test-client" })
      end

      it "responds with 200 OK" do
        post "/api/oauth/revoke", params: { token: token }

        expect(response).to have_http_status(:ok)
      end

      it "revokes active device sessions for the account" do
        post "/api/oauth/revoke", params: { token: token }

        device_session.reload
        expect(device_session).to be_revoked
      end

      it "publishes a TOKEN_REVOKED event" do
        events = []
        subscriber = StandardId::Events.subscribe(StandardId::Events::OAUTH_TOKEN_REVOKED) do |event|
          events << event
        end

        begin
          post "/api/oauth/revoke", params: { token: token }

          expect(events.size).to eq(1)
          expect(events.first.payload[:account_id]).to eq(account.id)
          expect(events.first.payload[:sessions_revoked]).to eq(1)
        ensure
          StandardId::Events.unsubscribe(subscriber)
        end
      end

      it "accepts optional token_type_hint parameter" do
        post "/api/oauth/revoke", params: { token: token, token_type_hint: "access_token" }

        expect(response).to have_http_status(:ok)
        device_session.reload
        expect(device_session).to be_revoked
      end
    end

    context "with an invalid token" do
      it "responds with 200 OK per RFC 7009" do
        post "/api/oauth/revoke", params: { token: "invalid.jwt.token" }

        expect(response).to have_http_status(:ok)
      end

      it "returns an empty body" do
        post "/api/oauth/revoke", params: { token: "invalid.jwt.token" }

        expect(response.body).to be_empty
      end
    end

    context "with a missing token parameter" do
      it "responds with 200 OK per RFC 7009" do
        post "/api/oauth/revoke", params: {}

        expect(response).to have_http_status(:ok)
      end
    end

    context "with an expired token" do
      let(:token) do
        StandardId::JwtService.encode({ sub: account.id, client_id: "test-client" }, expires_in: -1.hour)
      end

      it "responds with 200 OK per RFC 7009" do
        post "/api/oauth/revoke", params: { token: token }

        expect(response).to have_http_status(:ok)
      end
    end

    context "with a token lacking a sub claim" do
      let(:token) do
        StandardId::JwtService.encode({ client_id: "test-client" })
      end

      it "responds with 200 OK without revoking anything" do
        post "/api/oauth/revoke", params: { token: token }

        expect(response).to have_http_status(:ok)
      end
    end

    context "when no active device sessions exist" do
      let(:token) do
        StandardId::JwtService.encode({ sub: account.id, client_id: "test-client" })
      end

      it "responds with 200 OK" do
        post "/api/oauth/revoke", params: { token: token }

        expect(response).to have_http_status(:ok)
      end

      it "does not publish a TOKEN_REVOKED event" do
        events = []
        subscriber = StandardId::Events.subscribe(StandardId::Events::OAUTH_TOKEN_REVOKED) do |event|
          events << event
        end

        begin
          post "/api/oauth/revoke", params: { token: token }

          expect(events).to be_empty
        ensure
          StandardId::Events.unsubscribe(subscriber)
        end
      end
    end

    context "with multiple active device sessions" do
      let!(:device_sessions) do
        3.times.map do |i|
          StandardId::DeviceSession.create!(
            account: account,
            device_id: "device-#{i}-#{SecureRandom.hex(4)}",
            device_agent: "MyApp/1.0 (iPhone; iOS 14.6)",
            expires_at: 2.weeks.from_now
          )
        end
      end

      let(:token) do
        StandardId::JwtService.encode({ sub: account.id, client_id: "test-client" })
      end

      it "revokes all active device sessions" do
        post "/api/oauth/revoke", params: { token: token }

        device_sessions.each do |session|
          session.reload
          expect(session).to be_revoked
        end
      end

      it "publishes one SESSION_REVOKED event per revoked session" do
        events = []
        subscriber = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) do |event|
          events << event
        end

        begin
          post "/api/oauth/revoke", params: { token: token }
        ensure
          StandardId::Events.unsubscribe(subscriber)
        end

        expect(events.size).to eq(3)
        expect(events.map { |e| e.payload[:session].id }).to match_array(device_sessions.map(&:id))
        events.each do |event|
          expect(event.payload[:account]).to eq(account)
          expect(event.payload[:reason]).to eq("token_revocation")
        end
      end
    end

    context "when a SESSION_REVOKED subscriber raises" do
      let!(:device_sessions) do
        3.times.map do |i|
          StandardId::DeviceSession.create!(
            account: account,
            device_id: "device-#{i}-#{SecureRandom.hex(4)}",
            device_agent: "MyApp/1.0",
            expires_at: 2.weeks.from_now
          )
        end
      end

      let(:token) do
        StandardId::JwtService.encode({ sub: account.id, client_id: "test-client" })
      end

      it "still revokes all sessions and publishes OAUTH_TOKEN_REVOKED" do
        logger = instance_double(Logger, error: nil, info: nil, warn: nil, debug: nil)
        allow(StandardId).to receive(:logger).and_return(logger)

        failing = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) do |_event|
          raise "subscriber boom"
        end

        token_revoked_events = []
        token_revoked_sub = StandardId::Events.subscribe(StandardId::Events::OAUTH_TOKEN_REVOKED) do |event|
          token_revoked_events << event
        end

        begin
          post "/api/oauth/revoke", params: { token: token }
        ensure
          StandardId::Events.unsubscribe(failing)
          StandardId::Events.unsubscribe(token_revoked_sub)
        end

        expect(response).to have_http_status(:ok)
        device_sessions.each { |s| expect(s.reload).to be_revoked }
        expect(token_revoked_events.size).to eq(1)
        expect(token_revoked_events.first.payload[:sessions_revoked]).to eq(3)
        expect(logger).to have_received(:error)
          .with(/Failed to publish SESSION_REVOKED/).at_least(:once)
      end
    end

    context "with already revoked sessions" do
      let!(:revoked_session) do
        session = StandardId::DeviceSession.create!(
          account: account,
          device_id: "device-#{SecureRandom.hex(4)}",
          device_agent: "MyApp/1.0 (iPhone; iOS 14.6)",
          expires_at: 2.weeks.from_now
        )
        session.revoke!
        session
      end

      let(:token) do
        StandardId::JwtService.encode({ sub: account.id, client_id: "test-client" })
      end

      it "responds with 200 OK and does not re-revoke" do
        original_revoked_at = revoked_session.reload.revoked_at

        post "/api/oauth/revoke", params: { token: token }

        expect(response).to have_http_status(:ok)
        expect(revoked_session.reload.revoked_at).to eq(original_revoked_at)
      end
    end

    describe "config.oauth.revocation_scope" do
      # StandardId.config is process-global; restore it so the opt-in doesn't
      # leak into the rest of the suite.
      around do |example|
        original = StandardId.config.oauth.revocation_scope
        example.run
      ensure
        StandardId.config.oauth.revocation_scope = original
      end

      it "defaults to :account (the historical blast radius)" do
        expect(StandardId.config.oauth.revocation_scope).to eq(:account)
      end

      context "when set to :grant" do
        before { StandardId.configure { |c| c.oauth.revocation_scope = :grant } }

        let!(:session) do
          StandardId::DeviceSession.create!(
            account: account,
            device_id: "device-#{SecureRandom.hex(4)}",
            device_agent: "MyApp/1.0",
            expires_at: 2.weeks.from_now
          )
        end

        let!(:other_session) do
          StandardId::DeviceSession.create!(
            account: account,
            device_id: "other-#{SecureRandom.hex(4)}",
            device_agent: "OtherApp/1.0",
            expires_at: 2.weeks.from_now
          )
        end

        # A refresh token bound to `session`, plus the rotated successor that
        # shares its family.
        let(:jti) { SecureRandom.uuid }

        let!(:refresh_token) do
          StandardId::RefreshToken.create!(
            account_id: account.id,
            session_id: session.id,
            token_digest: StandardId::RefreshToken.digest_for(jti),
            expires_at: 30.days.from_now
          )
        end

        let!(:successor) do
          StandardId::RefreshToken.create!(
            account_id: account.id,
            session_id: session.id,
            token_digest: StandardId::RefreshToken.digest_for(SecureRandom.uuid),
            expires_at: 30.days.from_now,
            previous_token: refresh_token
          )
        end

        let(:refresh_jwt) do
          StandardId::JwtService.encode(
            { sub: account.id, client_id: "test-client", grant_type: "refresh_token", jti: jti }
          )
        end

        let(:access_jwt) do
          StandardId::JwtService.encode(
            { sub: account.id, client_id: "test-client", jti: SecureRandom.uuid }
          )
        end

        it "revokes only the presented grant's session" do
          post "/api/oauth/revoke", params: { token: refresh_jwt }

          expect(response).to have_http_status(:ok)
          expect(session.reload).to be_revoked
          expect(other_session.reload).not_to be_revoked
        end

        it "revokes the whole refresh-token family" do
          post "/api/oauth/revoke", params: { token: refresh_jwt }

          expect(refresh_token.reload).to be_revoked
          expect(successor.reload).to be_revoked
        end

        it "reports both counts on OAUTH_TOKEN_REVOKED" do
          events = []
          subscriber = StandardId::Events.subscribe(StandardId::Events::OAUTH_TOKEN_REVOKED) do |event|
            events << event
          end

          begin
            post "/api/oauth/revoke", params: { token: refresh_jwt }
          ensure
            StandardId::Events.unsubscribe(subscriber)
          end

          expect(events.size).to eq(1)
          expect(events.first.payload[:sessions_revoked]).to eq(1)
          expect(events.first.payload[:refresh_tokens_revoked]).to eq(2)
        end

        it "publishes SESSION_REVOKED only for the grant's session" do
          events = []
          subscriber = StandardId::Events.subscribe(StandardId::Events::SESSION_REVOKED) do |event|
            events << event
          end

          begin
            post "/api/oauth/revoke", params: { token: refresh_jwt }
          ensure
            StandardId::Events.unsubscribe(subscriber)
          end

          expect(events.map { |e| e.payload[:session].id }).to eq([session.id])
        end

        it "still revokes the family when the grant has no linked session" do
          refresh_token.update!(session_id: nil)
          successor.update!(session_id: nil)

          post "/api/oauth/revoke", params: { token: refresh_jwt }

          expect(response).to have_http_status(:ok)
          expect(refresh_token.reload).to be_revoked
          expect(session.reload).not_to be_revoked
        end

        it "revokes nothing for a stateless access token" do
          post "/api/oauth/revoke", params: { token: access_jwt }

          expect(response).to have_http_status(:ok)
          expect(session.reload).not_to be_revoked
          expect(other_session.reload).not_to be_revoked
          expect(refresh_token.reload).not_to be_revoked
        end

        it "revokes nothing for a token with no jti" do
          token = StandardId::JwtService.encode({ sub: account.id, client_id: "test-client" })

          post "/api/oauth/revoke", params: { token: token }

          expect(response).to have_http_status(:ok)
          expect(session.reload).not_to be_revoked
        end

        it "ignores a jti belonging to another subject's grant" do
          other_account = Account.create!(name: "Other", email: "other-#{SecureRandom.hex(4)}@example.com")
          foreign_jwt = StandardId::JwtService.encode(
            { sub: other_account.id, client_id: "test-client", jti: jti }
          )

          post "/api/oauth/revoke", params: { token: foreign_jwt }

          expect(response).to have_http_status(:ok)
          expect(refresh_token.reload).not_to be_revoked
          expect(session.reload).not_to be_revoked
        end

        it "ignores token_type_hint — the jti lookup is type-agnostic" do
          post "/api/oauth/revoke", params: { token: refresh_jwt, token_type_hint: "access_token" }

          expect(response).to have_http_status(:ok)
          expect(refresh_token.reload).to be_revoked
        end
      end

      context "when set to an unrecognised value" do
        before { StandardId.configure { |c| c.oauth.revocation_scope = :nonsense } }

        let!(:device_session) do
          StandardId::DeviceSession.create!(
            account: account,
            device_id: "device-#{SecureRandom.hex(4)}",
            device_agent: "MyApp/1.0",
            expires_at: 2.weeks.from_now
          )
        end

        let(:token) { StandardId::JwtService.encode({ sub: account.id, client_id: "test-client" }) }

        it "warns and falls back to the fail-safe :account behaviour" do
          logger = instance_double(Logger, warn: nil, error: nil, info: nil, debug: nil)
          allow(StandardId).to receive(:logger).and_return(logger)

          post "/api/oauth/revoke", params: { token: token }

          expect(response).to have_http_status(:ok)
          expect(device_session.reload).to be_revoked
          expect(logger).to have_received(:warn).with(/revocation_scope/)
        end
      end
    end

    it "sets no-store cache headers" do
      post "/api/oauth/revoke", params: { token: "some-token" }

      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.headers["Pragma"]).to eq("no-cache")
    end
  end
end
