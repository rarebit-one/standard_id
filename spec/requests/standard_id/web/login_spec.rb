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
      it "redirects directly to Google OAuth" do
        allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
        allow(StandardId.config).to receive(:google_client_secret).and_return("google-secret")

        http_post "/login", params: { connection: "google", redirect_uri: "/after", login: { email: "", password: "" } }

        expect(response).to have_http_status(:found)
        expect(response.location).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")
        expect(response.location).to include("client_id=google_client_123")
        expect(response.location).to include("state=")
        expect(response.location).to include("redirect_uri=" + CGI.escape("http://www.example.com/auth/callback/google"))
      end
    end

    context "when password login is attempted" do
      it "signs in and redirects on valid credentials" do
        create_account_with_password(email: email, password: password)

        http_post "/login", params: { login: { email: email, password: password }, redirect_uri: "/after" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to("/after")
      end

      it "ignores Array-shaped redirect_uri instead of crashing on redirect_to" do
        create_account_with_password(email: email, password: password)

        # Rails would parse redirect_uri[]=/a&redirect_uri[]=/b as an Array; without the
        # string_param guard, the destination chain feeds the Array into redirect_to and 500s.
        http_post "/login", params: { login: { email: email, password: password }, redirect_uri: ["/a", "/b"] }

        expect(response).to have_http_status(:see_other)
        # Falls through to after_authentication_url since redirect_uri was not a String
        expect(response).to redirect_to("/")
      end

      it "rejects cross-host redirect_uri not in the allow list" do
        create_account_with_password(email: email, password: password)

        http_post "/login", params: { login: { email: email, password: password }, redirect_uri: "https://evil.example.com/phish" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to("/")
      end

      it "rejects protocol-relative redirect_uri" do
        create_account_with_password(email: email, password: password)

        http_post "/login", params: { login: { email: email, password: password }, redirect_uri: "//evil.example.com/phish" }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to("/")
      end

      it "accepts same-origin absolute redirect_uri (store_location_for_redirect compatibility)" do
        create_account_with_password(email: email, password: password)
        # request.url on dummy app is http://www.example.com — match the base_url
        same_origin = "http://www.example.com/admin/users"

        http_post "/login", params: { login: { email: email, password: password }, redirect_uri: same_origin }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(same_origin)
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
