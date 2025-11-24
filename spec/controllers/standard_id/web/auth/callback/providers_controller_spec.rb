require "rails_helper"

RSpec.describe StandardId::Web::Auth::Callback::ProvidersController, type: :controller do
  render_views
  routes { StandardId::WebEngine.routes }

  let(:redirect_uri) { "sidekicklabs://apple-signin" }
  let(:state_payload) { { "redirect_uri" => redirect_uri } }
  let(:encoded_state) { Base64.urlsafe_encode64(state_payload.to_json) }

  before do
    StandardId.config.allowed_redirect_url_prefixes = ["sidekicklabs://"]
  end

  after do
    StandardId.config.allowed_redirect_url_prefixes = []
  end

  describe "POST #apple_mobile" do
    it "renders an auto-redirecting page for allowed schemes" do
      post :apple_mobile, params: { state: encoded_state, code: "abc123" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include("window.location.replace")
      expect(response.body).to include("sidekicklabs://apple-signin")
      expect(response.body).to include("code=abc123")
    end

    it "rejects disallowed redirect URIs" do
      bad_state = Base64.urlsafe_encode64({ "redirect_uri" => "https://example.com" }.to_json)

      post :apple_mobile, params: { state: bad_state }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to match(/not allowed/)
    end
  end
end
