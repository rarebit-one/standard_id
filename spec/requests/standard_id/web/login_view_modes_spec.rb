require "rails_helper"

# Change E: the ERB login view selects its form on the same passwordless-first
# precedence the controller's #create uses.
RSpec.describe "StandardId Web Login view modes", type: :request do
  describe "GET /login" do
    context "passwordless-only mode" do
      before do
        allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
        allow(StandardId.config.web).to receive(:password_login).and_return(false)
      end

      it "renders an email-only form with no password field" do
        http_get "/login"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('name="login[email]"')
        expect(response.body).not_to include('name="login[password]"')
      end

      it "does not render the external tailwindcss.com logo (asset-free branch)" do
        http_get "/login"
        expect(response.body).not_to include("tailwindcss.com")
      end
    end

    context "passwordless-first when both are enabled" do
      before do
        allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
        allow(StandardId.config.web).to receive(:password_login).and_return(true)
      end

      it "renders the passwordless (email-only) form, no password field" do
        http_get "/login"
        expect(response.body).to include('name="login[email]"')
        expect(response.body).not_to include('name="login[password]"')
      end
    end

    context "double-submit guard (passwordless form)" do
      before do
        allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
        allow(StandardId.config.web).to receive(:password_login).and_return(false)
      end

      it "renders the progressive-enhancement guard script targeting the form" do
        http_get "/login"

        expect(response.body).to include('id="passwordless-login-form"')
        expect(response.body).to include("passwordless-login-form")
        expect(response.body).to include("addEventListener(\"submit\"")
        expect(response.body).to include("btn.disabled = true")
      end
    end

    context "password mode (default) — regression guard" do
      before do
        allow(StandardId.config.web).to receive(:passwordless_login).and_return(false)
        allow(StandardId.config.web).to receive(:password_login).and_return(true)
      end

      it "renders the unchanged password form" do
        http_get "/login"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('name="login[email]"')
        expect(response.body).to include('name="login[password]"')
      end
    end

    context "no login method enabled" do
      before do
        allow(StandardId.config.web).to receive(:passwordless_login).and_return(false)
        allow(StandardId.config.web).to receive(:password_login).and_return(false)
      end

      it "renders a message and does not crash" do
        http_get "/login"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No login method is enabled")
        expect(response.body).not_to include('name="login[password]"')
      end
    end

    # 0.21.1: the login view must respect the web.signup / web.password_reset
    # toggles so an app that disables them doesn't render links to 404 routes.
    context "link gating on web toggles" do
      it "hides the Sign up link (passwordless mode) when signup is disabled" do
        allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
        allow(StandardId.config.web).to receive(:password_login).and_return(false)
        allow(StandardId.config.web).to receive(:signup).and_return(false)
        http_get "/login"
        expect(response.body).not_to include("Sign up")
      end

      it "shows the Sign up link (passwordless mode) when signup is enabled" do
        allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
        allow(StandardId.config.web).to receive(:password_login).and_return(false)
        allow(StandardId.config.web).to receive(:signup).and_return(true)
        http_get "/login"
        expect(response.body).to include("Sign up")
      end

      it "hides the Forgot password link (password mode) when password_reset is disabled" do
        allow(StandardId.config.web).to receive(:passwordless_login).and_return(false)
        allow(StandardId.config.web).to receive(:password_login).and_return(true)
        allow(StandardId.config.web).to receive(:password_reset).and_return(false)
        http_get "/login"
        expect(response.body).not_to include("Forgot password?")
      end
    end
  end
end
