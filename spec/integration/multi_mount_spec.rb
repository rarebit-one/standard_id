require "rails_helper"

RSpec.describe "Multiple WebEngine mounts with scope defaults", type: :request do
  let(:email) { "multi-mount@example.com" }
  let(:password) { "s3cureP@ss" }

  # Draw additional scoped mounts for the duration of these tests, then
  # restore the original routes so other specs are unaffected.
  around do |example|
    original_scopes = StandardId.config.scopes
    StandardId.config.scopes = {
      borrower: {
        label: "Borrower Portal",
        after_sign_in_path: "/borrower/dashboard"
      },
      lender: {
        label: "Lender Portal",
        after_sign_in_path: "/lender/dashboard"
      }
    }

    Rails.application.routes.draw do
      mount StandardId::WebEngine => "/", as: :standard_id_web
      mount StandardId::WebEngine => "/borrower", as: :standard_id_web_borrower, defaults: { scope: :borrower }
      mount StandardId::WebEngine => "/lender", as: :standard_id_web_lender, defaults: { scope: :lender }

      root to: "public#info"

      namespace :util do
        post "/session", to: "session#set"
      end
    end

    example.run
  ensure
    StandardId.config.scopes = original_scopes
    Rails.application.routes_reloader.reload!
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Route isolation
  # ───────────────────────────────────────────────────────────────────────────
  describe "route isolation" do
    it "generates distinct routes for each scoped mount" do
      # The default (unscoped) mount
      expect(Rails.application.routes.recognize_path("/login")).to include(
        controller: "standard_id/web/login",
        action: "show"
      )

      # Borrower-scoped mount
      expect(Rails.application.routes.recognize_path("/borrower/login")).to include(
        controller: "standard_id/web/login",
        action: "show"
      )

      # Lender-scoped mount
      expect(Rails.application.routes.recognize_path("/lender/login")).to include(
        controller: "standard_id/web/login",
        action: "show"
      )
    end

    it "generates distinct routes for signup on each mount" do
      expect(Rails.application.routes.recognize_path("/signup")).to include(
        controller: "standard_id/web/signup",
        action: "show"
      )

      expect(Rails.application.routes.recognize_path("/borrower/signup")).to include(
        controller: "standard_id/web/signup",
        action: "show"
      )

      expect(Rails.application.routes.recognize_path("/lender/signup")).to include(
        controller: "standard_id/web/signup",
        action: "show"
      )
    end

    it "resolves each mount to the same controller with distinct scope defaults" do
      # Each mount prefix should resolve independently
      unscoped = Rails.application.routes.recognize_path("/login")
      borrower = Rails.application.routes.recognize_path("/borrower/login")
      lender   = Rails.application.routes.recognize_path("/lender/login")

      # All route to the same controller/action
      expect(unscoped[:controller]).to eq(borrower[:controller])
      expect(borrower[:controller]).to eq(lender[:controller])

      # But the scope default differs
      expect(unscoped[:scope]).to be_nil
      expect(borrower[:scope]).to eq(:borrower)
      expect(lender[:scope]).to eq(:lender)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Scope flows through to controllers
  # ───────────────────────────────────────────────────────────────────────────
  describe "scope flows through to controllers" do
    it "renders login page on borrower-scoped mount" do
      http_get "/borrower/login"

      expect(response).to have_http_status(:ok)
    end

    it "renders login page on lender-scoped mount" do
      http_get "/lender/login"

      expect(response).to have_http_status(:ok)
    end

    it "includes borrower scope in after_sign_in hook context" do
      create_account_with_password(email: email, password: password)

      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/borrower/login", params: { login: { email: email, password: password } }

      expect(response).to have_http_status(:see_other)
      expect(received_context).to include(scope: :borrower)
    end

    it "includes lender scope in after_sign_in hook context" do
      create_account_with_password(email: email, password: password)

      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/lender/login", params: { login: { email: email, password: password } }

      expect(response).to have_http_status(:see_other)
      expect(received_context).to include(scope: :lender)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Different scopes on different mounts
  # ───────────────────────────────────────────────────────────────────────────
  describe "different scopes on different mounts" do
    before { create_account_with_password(email: email, password: password) }

    it "passes borrower scope config with correct after_sign_in_path" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/borrower/login", params: { login: { email: email, password: password } }

      expect(received_context[:scope]).to eq(:borrower)
      expect(received_context[:after_sign_in_path]).to eq("/borrower/dashboard")
    end

    it "passes lender scope config with correct after_sign_in_path" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/lender/login", params: { login: { email: email, password: password } }

      expect(received_context[:scope]).to eq(:lender)
      expect(received_context[:after_sign_in_path]).to eq("/lender/dashboard")
    end

    it "redirects to borrower dashboard after login on borrower mount" do
      http_post "/borrower/login", params: { login: { email: email, password: password } }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/borrower/dashboard")
    end

    it "redirects to lender dashboard after login on lender mount" do
      http_post "/lender/login", params: { login: { email: email, password: password } }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/lender/dashboard")
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Backward compatibility — unscoped mount
  # ───────────────────────────────────────────────────────────────────────────
  describe "backward compatibility" do
    it "renders login page on unscoped mount" do
      http_get "/login"

      expect(response).to have_http_status(:ok)
    end

    it "does not include scope in after_sign_in context for unscoped mount" do
      create_account_with_password(email: email, password: password)

      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(response).to have_http_status(:see_other)
      expect(received_context).to be_a(Hash)
      expect(received_context).not_to have_key(:scope)
    end

    it "redirects to specified redirect_uri on unscoped mount" do
      create_account_with_password(email: email, password: password)

      http_post "/login", params: { login: { email: email, password: password }, redirect_uri: "/home" }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/home")
    end
  end
end
