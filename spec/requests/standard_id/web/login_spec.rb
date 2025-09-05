require "rails_helper"

RSpec.describe "StandardId Web Login", type: :request do
  let(:email) { "user@example.com" }
  let(:password) { "s3cureP@ss" }

  describe "GET /login" do
    context "when not authenticated" do
      it "renders the login page" do
        http_get "/login", params: { redirect_uri: "/dashboard" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("login")
      end
    end

    context "when already authenticated" do
      it "redirects to after_authentication_url" do
        account = Account.create!(name: "Auth'd", email: "authd@example.com")
        session = StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 30.days.from_now)
        post util_session_path, params: { session_token: session.token }

        http_get "/login"
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to("/")
      end
    end
  end

  describe "POST /login" do
    context "when social login connection is present" do
      it "redirects to social login URL with connection param" do
        StandardId.config.define_singleton_method(:default_client_id) { "web_client" }

        http_post "/login", params: { connection: "google-oauth2", redirect_uri: "/after", login: { email: "", password: "" } }

        expect(response).to have_http_status(:found)
        expect(response.location).to start_with("http://www.example.com/api/authorize?")
        expect(response.location).to include("connection=google-oauth2")
        expect(response.location).to include("client_id=web_client")
      end
    end

    context "when password login is attempted" do
      it "signs in and redirects on valid credentials" do
        create_account_with_password(email: email, password: password)

        http_post "/login", params: { login: { email: email, password: password }, redirect_uri: "/after" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to("/after")
      end

      it "renders the form with error on invalid credentials" do
        create_account_with_password(email: email, password: password)

        http_post "/login", params: { login: { email: email, password: "wrong" } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(flash[:alert]).to eq("Invalid email or password")
      end

      it "sets remember_token cookie when remember_me is checked" do
        create_account_with_password(email: email, password: password)

        http_post "/login", params: { login: { email: email, password: password, remember_me: "1" }, redirect_uri: "/after" }

        expect(response).to have_http_status(:see_other)
        expect(cookies["remember_token"]).to be_present
      end

      it "does not set remember_token cookie when remember_me is not checked" do
        create_account_with_password(email: email, password: password)

        http_post "/login", params: { login: { email: email, password: password, remember_me: "0" }, redirect_uri: "/after" }

        expect(response).to have_http_status(:see_other)
        expect(cookies["remember_token"]).to be_blank
      end
    end
  end
end
