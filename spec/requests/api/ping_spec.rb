require "rails_helper"

RSpec.describe "API Ping", type: :request do
  let(:account) { Account.create!(name: "Test Service", email: "service@example.com") }

  context "when authenticated" do
    let(:jwt) { StandardId::JwtService.encode({ sub: account.id, client_id: "svc-1", scope: "service:read", grant_type: "access_token" }) }

    describe "GET /api/ping" do
      it "returns 200 and JSON status ok" do
        http_get api_ping_path, headers: auth_headers(jwt)
        expect(response).to have_http_status(:ok)
        json = json_body
        expect(json["status"]).to eq("ok")
        expect(json).to have_key("timestamp")
      end
    end
  end

  context "when not authenticated" do
    describe "GET /api/ping" do
      it "returns 401 Unauthorized" do
        http_get api_ping_path
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
