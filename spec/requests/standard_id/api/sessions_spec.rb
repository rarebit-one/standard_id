require "rails_helper"

RSpec.describe "StandardId::Api::SessionsController", type: :request do
  let(:account) { Account.create!(name: "Test User", email: "sessions-#{SecureRandom.hex(4)}@example.com") }
  let(:access_token) { StandardId::JwtService.encode({ sub: account.id, client_id: "test-client", scope: "read" }) }
  let(:auth_headers) { { "Authorization" => "Bearer #{access_token}" } }

  describe "GET /api/sessions" do
    context "with a valid token" do
      let!(:device_session) do
        StandardId::DeviceSession.create!(
          account: account,
          device_id: "device-#{SecureRandom.hex(4)}",
          device_agent: "MyApp/1.0 (iPhone; iOS 14.6)",
          expires_at: 2.weeks.from_now
        )
      end

      it "returns the account's active sessions" do
        get "/api/sessions", headers: auth_headers

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body).to be_an(Array)
        expect(body.size).to eq(1)
        expect(body.first["id"]).to eq(device_session.id)
        expect(body.first["type"]).to eq("DeviceSession")
      end

      it "does not include revoked sessions" do
        device_session.revoke!

        get "/api/sessions", headers: auth_headers

        body = response.parsed_body
        expect(body).to be_empty
      end
    end

    context "without a token" do
      it "returns 401" do
        get "/api/sessions"

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "DELETE /api/sessions/:id" do
    let!(:device_session) do
      StandardId::DeviceSession.create!(
        account: account,
        device_id: "device-#{SecureRandom.hex(4)}",
        device_agent: "MyApp/1.0 (iPhone; iOS 14.6)",
        expires_at: 2.weeks.from_now
      )
    end

    context "with a valid token" do
      it "revokes the session and returns 204" do
        delete "/api/sessions/#{device_session.id}", headers: auth_headers

        expect(response).to have_http_status(:no_content)
        expect(device_session.reload).to be_revoked
      end
    end

    context "with a non-existent session" do
      it "returns 404" do
        delete "/api/sessions/00000000-0000-0000-0000-000000000000", headers: auth_headers

        expect(response).to have_http_status(:not_found)
      end
    end

    context "when session belongs to another account" do
      let(:other_account) { Account.create!(name: "Other User", email: "other-#{SecureRandom.hex(4)}@example.com") }
      let!(:other_session) do
        StandardId::DeviceSession.create!(
          account: other_account,
          device_id: "device-#{SecureRandom.hex(4)}",
          device_agent: "MyApp/1.0",
          expires_at: 2.weeks.from_now
        )
      end

      it "returns 404 and does not revoke the session" do
        delete "/api/sessions/#{other_session.id}", headers: auth_headers

        expect(response).to have_http_status(:not_found)
        expect(other_session.reload).not_to be_revoked
      end
    end

    context "without a token" do
      it "returns 401" do
        delete "/api/sessions/#{device_session.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
