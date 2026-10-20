require "rails_helper"

RSpec.describe StandardId::Web::Auth::Callback::ProvidersController, type: :controller do
  render_views
  routes { StandardId::WebEngine.routes }

  let(:redirect_uri) { "sidekicklabs://apple-signin" }
  let(:state_token) { SecureRandom.urlsafe_base64(32) }

  def setup_oauth_session(state:, redirect_uri:, nonce: nil)
    # Use the controller's own method to ensure consistency
    controller.send(:store_oauth_request,
      state: state,
      nonce: nonce,
      params: { "redirect_uri" => redirect_uri }
    )
  end

  before do
    StandardId.config.allowed_redirect_url_prefixes = ["sidekicklabs://"]
  end

  after do
    StandardId.config.allowed_redirect_url_prefixes = []
  end

  describe "POST #mobile_callback" do
    it "renders an auto-redirecting page for allowed schemes" do
      setup_oauth_session(state: state_token, redirect_uri: redirect_uri)
      post :mobile_callback, params: { provider: "apple", state: state_token, code: "abc123" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include("window.location.replace")
      expect(response.body).to include("sidekicklabs://apple-signin")
      expect(response.body).to include("code=abc123")
    end

    it "keeps every relayed key intact in the redirect, not HTML-escaped" do
      setup_oauth_session(state: state_token, redirect_uri: redirect_uri)
      post :mobile_callback, params: { provider: "apple", state: state_token, code: "abc123", id_token: "tok" }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("&amp;")
      expect(response.body).to include("code=abc123\\u0026id_token=tok\\u0026state=#{state_token}")
    end

    it "relays Apple's cancel error to the app" do
      setup_oauth_session(state: state_token, redirect_uri: redirect_uri)
      post :mobile_callback, params: { provider: "apple", state: state_token, error: "user_cancelled_authorize" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("error=user_cancelled_authorize")
      expect(response.body).not_to include("code=")
    end

    it "rejects disallowed redirect URIs" do
      bad_redirect_uri = "https://example.com"
      setup_oauth_session(state: state_token, redirect_uri: bad_redirect_uri)
      post :mobile_callback, params: { provider: "apple", state: state_token }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to match(/not allowed/)
    end

    it "rejects unknown providers" do
      setup_oauth_session(state: state_token, redirect_uri: redirect_uri)
      expect {
        post :mobile_callback, params: { provider: "unknown", state: state_token }
      }.to raise_error(StandardId::InvalidRequestError, /Unknown provider/)
    end

    it "rejects providers that don't support mobile callback" do
      setup_oauth_session(state: state_token, redirect_uri: redirect_uri)
      post :mobile_callback, params: { provider: "google", state: state_token }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to match(/does not support mobile callback/)
    end
  end
end
