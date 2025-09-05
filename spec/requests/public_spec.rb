require "rails_helper"

RSpec.describe "Public", type: :request do
  describe "GET /" do
    it "returns 200 and renders the dashboard" do
      http_get "/"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Dashboard")
    end
  end
end
