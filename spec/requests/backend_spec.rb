require "rails_helper"

RSpec.describe "Backend", type: :request do
  describe "GET /backend" do
    it "returns 200 and renders the dashboard" do
      get backend_root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Backend Dashboard")
    end
  end
end
