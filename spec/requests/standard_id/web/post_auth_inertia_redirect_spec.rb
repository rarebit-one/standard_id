require "rails_helper"

# Regression for a production 500 on jumpdrive-web's MCP OAuth sign-in:
#
#   NoMethodError: undefined method 'inertia_configuration'
#     for an instance of StandardId::Api::AuthorizationController
#   GET /auth/api/authorize   (X-Inertia: true)
#   inertia_rails/middleware.rb:95 server_version
#
# When a host sets `use_inertia`, the WebEngine's auth pages are Inertia
# components, so login / OTP-verify / signup submits arrive as Inertia XHRs. A
# plain `redirect_to` made the Inertia client follow the redirect with its
# X-Inertia header still attached. When the destination is not an Inertia
# controller — the canonical case being the ApiEngine's /api/authorize, which
# inherits ActionController::API and so never receives inertia_rails' Controller
# module (it is included via `on_load(:action_controller_base)`) —
# inertia_rails' middleware calls #inertia_configuration on it and raises.
#
# The post-auth redirects must therefore emit 409 + X-Inertia-Location, which
# makes the client perform a full page visit and drop the header.
RSpec.describe "StandardId Web post-authentication Inertia redirects", :inertia, type: :request do
  let(:email) { "inertia-redirect@example.com" }
  let(:password) { "s3cureP@ss" }
  let(:inertia_headers) { { "X-Inertia" => "true" } }

  # The exact destination shape from the production trace: an ApiEngine endpoint
  # reached from the WebEngine's Inertia-rendered auth pages. Same-origin — which
  # is why "only redirect_with_inertia for external URLs" would NOT fix this.
  let(:api_destination) { "/api/authorize?client_id=abc&response_type=code" }

  def enable_passwordless!
    allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
    allow(StandardId.config.passwordless).to receive(:connection).and_return("email")
    allow(StandardId.config).to receive(:passwordless_email_sender)
      .and_return(double("sender", call: true))
  end

  describe "PATCH /login_verify (passwordless OTP — the path that 500'd)" do
    before do
      enable_passwordless!
      account = Account.create!(name: "Test User", email: email)
      StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)

      http_post "/login", params: { login: { email: email }, redirect_uri: api_destination }
      expect(response).to redirect_to("/login_verify")
    end

    def verify_otp!(headers: {})
      code = StandardId::CodeChallenge.last.code.to_s
      http_patch "/login_verify", params: { code: code }, headers: headers
    end

    it "emits 409 + X-Inertia-Location instead of a 303 the client would follow with X-Inertia" do
      verify_otp!(headers: inertia_headers)

      expect(response).to have_http_status(:conflict)
      expect(response.headers["X-Inertia-Location"]).to eq(api_destination)
      expect(response).not_to have_http_status(:see_other)
    end

    it "still signs the account in" do
      expect { verify_otp!(headers: inertia_headers) }
        .to change(StandardId::BrowserSession, :count).by(1)
    end

    it "preserves the sign-in notice across the Inertia branch" do
      verify_otp!(headers: inertia_headers)

      expect(flash[:notice]).to eq("Successfully signed in")
    end

    it "still issues a normal 303 redirect for a non-Inertia request" do
      verify_otp!

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(api_destination)
      expect(flash[:notice]).to eq("Successfully signed in")
    end
  end

  describe "POST /login (password)" do
    before do
      allow(StandardId.config.web).to receive(:passwordless_login).and_return(false)
      allow(StandardId.config.web).to receive(:password_login).and_return(true)
      create_account_with_password(email: email, password: password)
    end

    it "emits 409 + X-Inertia-Location for an Inertia request" do
      http_post "/login",
                params: { login: { email: email, password: password }, redirect_uri: api_destination },
                headers: inertia_headers

      expect(response).to have_http_status(:conflict)
      expect(response.headers["X-Inertia-Location"]).to eq(api_destination)
      expect(flash[:notice]).to eq("Successfully signed in")
    end

    it "still issues a normal 303 redirect for a non-Inertia request" do
      http_post "/login", params: { login: { email: email, password: password }, redirect_uri: api_destination }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(api_destination)
    end
  end

  describe "POST /signup" do
    it "emits 409 + X-Inertia-Location for an Inertia request" do
      http_post "/signup",
                params: {
                  signup: { email: email, password: password, password_confirmation: password },
                  redirect_uri: api_destination
                },
                headers: inertia_headers

      expect(response).to have_http_status(:conflict)
      expect(response.headers["X-Inertia-Location"]).to eq(api_destination)
      expect(flash[:notice]).to eq("Account created successfully")
    end

    it "still issues a normal 302 redirect for a non-Inertia request" do
      http_post "/signup",
                params: {
                  signup: { email: email, password: password, password_confirmation: password },
                  redirect_uri: api_destination
                }

      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(api_destination)
    end
  end

  # safe_destination? deliberately admits allow-listed cross-origin/custom-scheme
  # destinations (mobile deep links). Those need allow_other_host: on the plain
  # redirect_to branch or Rails raises UnsafeRedirectError.
  describe "allow-listed cross-scheme destination" do
    let(:deep_link) { "sidekicklabs://done" }

    around do |example|
      original = StandardId.config.allowed_redirect_url_prefixes
      StandardId.config.allowed_redirect_url_prefixes = ["sidekicklabs://"]
      example.run
      StandardId.config.allowed_redirect_url_prefixes = original
    end

    before do
      allow(StandardId.config.web).to receive(:passwordless_login).and_return(false)
      allow(StandardId.config.web).to receive(:password_login).and_return(true)
      create_account_with_password(email: email, password: password)
    end

    it "redirects without raising UnsafeRedirectError on the non-Inertia branch" do
      http_post "/login", params: { login: { email: email, password: password }, redirect_uri: deep_link }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(deep_link)
    end

    it "emits X-Inertia-Location for an Inertia request" do
      http_post "/login",
                params: { login: { email: email, password: password }, redirect_uri: deep_link },
                headers: inertia_headers

      expect(response).to have_http_status(:conflict)
      expect(response.headers["X-Inertia-Location"]).to eq(deep_link)
    end
  end
end
