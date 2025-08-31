require "rails_helper"

RSpec.describe "API Ping", type: :request do
  describe "GET /api/ping" do
    it "returns 200 and JSON status ok" do
      get api_ping_path
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("ok")
      expect(json).to have_key("timestamp")
    end
  end
end
