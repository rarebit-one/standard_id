require "rails_helper"

RSpec.describe "Public", type: :request do
  describe "GET /info" do
    it "returns 200 and renders the info page" do
      get "/info"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Dummy App Info")
    end
  end
end
