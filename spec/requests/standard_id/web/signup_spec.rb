require "rails_helper"

RSpec.describe "StandardId Web Signup", type: :request do
  describe "GET /signup" do
    context "when not authenticated" do
      it "renders the signup page" do
        http_get "/signup", params: { redirect_uri: "/welcome" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("signup")
      end
    end

    context "when already authenticated" do
      it "redirects to after_authentication_url" do
        account = Account.create!(name: "Auth'd", email: "authd@example.com")
        browser_session = StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 1.day.from_now)
        post util_session_path, params: { session_token: browser_session.token }

        http_get "/signup"
        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
      end
    end
  end

  describe "POST /signup" do
    context "when social signup connection is present" do
      it "redirects to social authorize URL with connection param" do
        StandardId.config.define_singleton_method(:default_client_id) { "web_client" }

        http_post "/signup", params: { connection: "google", redirect_uri: "/after", signup: { email: "", password: "", password_confirmation: "" } }

        expect(response).to have_http_status(:found)
        expect(response.location).to start_with("http://www.example.com/api/authorize?")
        expect(response.location).to include("connection=google")
        expect(response.location).to include("client_id=web_client")
      end
    end

    context "when password signup is attempted" do
      it "creates account artifacts, signs in, and redirects on valid input" do
        http_post "/signup", params: { signup: { email: "new@example.com", password: "s3cureP@ss", password_confirmation: "s3cureP@ss" }, redirect_uri: "/after" }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/after")
        expect(Account.find_by(email: "new@example.com")).to be_present
        identifier = StandardId::EmailIdentifier.find_by(value: "new@example.com")
        expect(identifier).to be_present
      end

      it "renders the form with error on invalid input" do
        http_post "/signup", params: { signup: { email: "bad", password: "short", password_confirmation: "mismatch" } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(flash[:alert]).to be_present
      end
    end
  end
end
