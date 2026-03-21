require "rails_helper"

RSpec.describe "Web Mechanism Gate", type: :request do
  # ─────────────────────────────────────────────────────────────────────────
  # Password login
  # ─────────────────────────────────────────────────────────────────────────
  describe "password login mechanism" do
    context "when password_login is enabled (default)" do
      it "attempts password authentication" do
        http_post "/login", params: { login: { email: "user@example.com", password: "wrong" } }
        # Should get unprocessable (bad credentials), not 404
        expect(response).not_to have_http_status(:not_found)
      end
    end

    context "when password_login is disabled" do
      before { allow(StandardId.config.web).to receive(:password_login).and_return(false) }

      it "returns 404 for POST /login with password" do
        http_post "/login", params: { login: { email: "user@example.com", password: "test1234" } }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Signup
  # ─────────────────────────────────────────────────────────────────────────
  describe "signup mechanism" do
    context "when signup is enabled (default)" do
      it "renders the signup page" do
        http_get "/signup"
        expect(response).to have_http_status(:ok)
      end
    end

    context "when signup is disabled" do
      before { allow(StandardId.config.web).to receive(:signup).and_return(false) }

      it "returns 404 for GET /signup" do
        http_get "/signup"
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for POST /signup" do
        http_post "/signup", params: { signup: { email: "a@b.com", password: "test1234", password_confirmation: "test1234" } }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Passwordless login
  # ─────────────────────────────────────────────────────────────────────────
  describe "passwordless login mechanism" do
    context "when passwordless_login is disabled (default)" do
      it "returns 404 for GET /login_verify" do
        http_get "/login_verify"
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for PATCH /login_verify" do
        http_patch "/login_verify", params: { code: "123456" }
        expect(response).to have_http_status(:not_found)
      end
    end

    context "when passwordless_login is enabled" do
      before { allow(StandardId.config.web).to receive(:passwordless_login).and_return(true) }

      it "does not return 404 for GET /login_verify" do
        http_get "/login_verify"
        # Will redirect to login (no OTP session), but should NOT be 404
        expect(response).not_to have_http_status(:not_found)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Social login
  # ─────────────────────────────────────────────────────────────────────────
  describe "social login mechanism" do
    context "when social_login is disabled" do
      before { allow(StandardId.config.web).to receive(:social_login).and_return(false) }

      it "returns 404 for GET /auth/callback/google" do
        http_get "/auth/callback/google", params: { code: "abc", state: "xyz" }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Password reset
  # ─────────────────────────────────────────────────────────────────────────
  describe "password reset mechanism" do
    context "when password_reset is enabled (default)" do
      it "renders the password reset start page" do
        http_get "/reset_password/start"
        expect(response).to have_http_status(:ok)
      end
    end

    context "when password_reset is disabled" do
      before { allow(StandardId.config.web).to receive(:password_reset).and_return(false) }

      it "returns 404 for GET /reset_password/start" do
        http_get "/reset_password/start"
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for POST /reset_password/start" do
        http_post "/reset_password/start", params: { email: "user@example.com" }
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for GET /reset_password/confirm" do
        http_get "/reset_password/confirm", params: { token: "abc" }
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Email verification
  # ─────────────────────────────────────────────────────────────────────────
  describe "email verification mechanism" do
    context "when email_verification is enabled (default)" do
      it "renders the email verification start page" do
        http_get "/verify_email/start"
        expect(response).to have_http_status(:ok)
      end
    end

    context "when email_verification is disabled" do
      before { allow(StandardId.config.web).to receive(:email_verification).and_return(false) }

      it "returns 404 for GET /verify_email/start" do
        http_get "/verify_email/start"
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Phone verification
  # ─────────────────────────────────────────────────────────────────────────
  describe "phone verification mechanism" do
    context "when phone_verification is enabled (default)" do
      it "renders the phone verification start page" do
        http_get "/verify_phone/start"
        expect(response).to have_http_status(:ok)
      end
    end

    context "when phone_verification is disabled" do
      before { allow(StandardId.config.web).to receive(:phone_verification).and_return(false) }

      it "returns 404 for GET /verify_phone/start" do
        http_get "/verify_phone/start"
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Sessions management
  # ─────────────────────────────────────────────────────────────────────────
  describe "sessions management mechanism" do
    let(:account) do
      Account.create!(name: "Test User", email: "sessions@example.com")
    end

    context "when sessions_management is enabled (default)" do
      it "renders the sessions index page" do
        as_user(account) do
          http_get "/sessions"
          expect(response).to have_http_status(:ok)
        end
      end
    end

    context "when sessions_management is disabled" do
      before { allow(StandardId.config.web).to receive(:sessions_management).and_return(false) }

      it "returns 404 for GET /sessions" do
        as_user(account) do
          http_get "/sessions"
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
