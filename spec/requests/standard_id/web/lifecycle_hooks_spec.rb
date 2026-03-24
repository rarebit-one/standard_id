require "rails_helper"

RSpec.describe "StandardId Web Lifecycle Hooks", type: :request do
  let(:email) { "hook-user@example.com" }
  let(:password) { "s3cureP@ss" }

  after do
    # Reset hooks after each test
    allow(StandardId.config).to receive(:after_sign_in).and_call_original
    allow(StandardId.config).to receive(:after_account_created).and_call_original
    allow(StandardId.config).to receive(:before_sign_in).and_call_original
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Password login
  # ───────────────────────────────────────────────────────────────────────────
  describe "password login" do
    before { create_account_with_password(email: email, password: password) }

    it "calls after_sign_in with correct arguments on password login" do
      hook = instance_double(Proc)
      allow(hook).to receive(:respond_to?).with(:call).and_return(true)
      allow(hook).to receive(:call).and_return(nil)
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(hook).to have_received(:call).with(
        an_instance_of(Account),
        an_instance_of(ActionDispatch::Request),
        hash_including(connection: "password", provider: nil, first_sign_in: true)
      )
      expect(response).to have_http_status(:see_other)
    end

    it "uses redirect override from after_sign_in hook" do
      hook = ->(_account, _request, _context) { "/onboarding" }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(response).to redirect_to("/onboarding")
    end

    it "rejects sign-in when after_sign_in raises AuthenticationDenied" do
      hook = ->(_account, _request, _context) { raise StandardId::AuthenticationDenied, "Access restricted" }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to eq("Access restricted")
    end

    it "sets first_sign_in false when account already has a session" do
      account = Account.find_by(email: email)
      StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 1.day.from_now)

      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(received_context[:first_sign_in]).to eq(false)
    end

    it "does not change behavior when no hooks are configured" do
      http_post "/login", params: { login: { email: email, password: password }, redirect_uri: "/dashboard" }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/dashboard")
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # before_sign_in hook — password login
  # ───────────────────────────────────────────────────────────────────────────
  describe "before_sign_in on password login" do
    before { create_account_with_password(email: email, password: password) }

    it "calls before_sign_in with correct arguments" do
      received_args = nil
      hook = lambda { |account, request, context|
        received_args = { account: account, request: request, context: context }
        nil
      }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(received_args[:account]).to be_an(Account)
      expect(received_args[:request]).to be_an(ActionDispatch::Request)
      expect(received_args[:context]).to include(mechanism: "password", provider: nil)
      expect(received_args[:context]).to have_key(:first_sign_in)
      expect(response).to have_http_status(:see_other)
    end

    it "proceeds with sign-in when hook returns nil" do
      hook = ->(_account, _request, _context) { nil }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(response).to have_http_status(:see_other)
    end

    it "proceeds with sign-in when hook returns truthy" do
      hook = ->(_account, _request, _context) { true }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(response).to have_http_status(:see_other)
    end

    it "rejects sign-in when hook returns error hash" do
      hook = ->(_account, _request, _context) { { error: "Account suspended" } }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to eq("Account suspended")
    end

    it "does not create a session when hook rejects sign-in" do
      hook = ->(_account, _request, _context) { { error: "Blocked" } }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      expect {
        http_post "/login", params: { login: { email: email, password: password } }
      }.not_to change(StandardId::BrowserSession, :count)
    end

    it "does not call after_sign_in when before_sign_in rejects" do
      before_hook = ->(_account, _request, _context) { { error: "Nope" } }
      after_hook = instance_double(Proc)
      allow(after_hook).to receive(:respond_to?).with(:call).and_return(true)
      allow(after_hook).to receive(:call)
      allow(StandardId.config).to receive(:before_sign_in).and_return(before_hook)
      allow(StandardId.config).to receive(:after_sign_in).and_return(after_hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(after_hook).not_to have_received(:call)
    end

    it "sets first_sign_in correctly" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(received_context[:first_sign_in]).to eq(true)
    end

    it "does not change behavior when no hook is configured" do
      http_post "/login", params: { login: { email: email, password: password }, redirect_uri: "/dashboard" }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/dashboard")
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # before_sign_in hook — signup
  # ───────────────────────────────────────────────────────────────────────────
  describe "before_sign_in on signup" do
    it "rejects sign-in when hook returns error hash during signup" do
      hook = ->(_account, _request, _context) { { error: "Registration closed" } }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      http_post "/signup", params: { signup: { email: "blocked@example.com", password: "s3cureP@ss", password_confirmation: "s3cureP@ss" } }

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to eq("Registration closed")
    end

    it "cleans up the account when before_sign_in rejects during signup" do
      hook = ->(_account, _request, _context) { { error: "Not allowed" } }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      expect {
        http_post "/signup", params: { signup: { email: "orphan2@example.com", password: "s3cureP@ss", password_confirmation: "s3cureP@ss" } }
      }.not_to change(Account, :count)

      expect(Account.find_by(email: "orphan2@example.com")).to be_nil
    end

    it "calls before_sign_in with mechanism: password for signup" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      http_post "/signup", params: { signup: { email: "new-hook@example.com", password: "s3cureP@ss", password_confirmation: "s3cureP@ss" } }

      expect(received_context).to include(mechanism: "password", provider: nil)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Passwordless login
  # ───────────────────────────────────────────────────────────────────────────
  describe "passwordless login" do
    let(:connection) { "email" }

    def enable_passwordless!
      allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
      allow(StandardId.config.passwordless).to receive(:connection).and_return(connection)
    end

    def initiate_passwordless_login!
      enable_passwordless!
      sender = double("email_sender")
      allow(sender).to receive(:call)
      allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)

      http_post "/login", params: { login: { email: email } }
      expect(response).to have_http_status(:see_other)
    end

    context "existing account" do
      before do
        account = Account.create!(name: "Test User", email: email)
        StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
      end

      it "calls after_sign_in with connection: email" do
        received_context = nil
        hook = lambda { |_account, _request, context|
          received_context = context
          nil
        }
        allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

        initiate_passwordless_login!
        challenge = StandardId::CodeChallenge.last
        http_patch "/login_verify", params: { code: challenge.code.to_s }

        expect(received_context[:connection]).to eq("email")
        expect(received_context[:provider]).to be_nil
      end

      it "does not call after_account_created for existing accounts" do
        account_hook = instance_double(Proc)
        allow(account_hook).to receive(:respond_to?).with(:call).and_return(true)
        allow(account_hook).to receive(:call)
        allow(StandardId.config).to receive(:after_account_created).and_return(account_hook)

        initiate_passwordless_login!
        challenge = StandardId::CodeChallenge.last
        http_patch "/login_verify", params: { code: challenge.code.to_s }

        expect(account_hook).not_to have_received(:call)
      end

      it "uses redirect override from after_sign_in hook" do
        hook = ->(_account, _request, _context) { "/welcome-back" }
        allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

        initiate_passwordless_login!
        challenge = StandardId::CodeChallenge.last
        http_patch "/login_verify", params: { code: challenge.code.to_s }

        expect(response).to redirect_to("/welcome-back")
      end

      it "rejects sign-in when after_sign_in raises AuthenticationDenied" do
        hook = ->(_account, _request, _context) { raise StandardId::AuthenticationDenied, "Not allowed" }
        allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

        initiate_passwordless_login!
        challenge = StandardId::CodeChallenge.last
        http_patch "/login_verify", params: { code: challenge.code.to_s }

        expect(response).to redirect_to("/login")
        expect(flash[:alert]).to eq("Not allowed")
      end

      it "calls before_sign_in with mechanism: passwordless" do
        received_context = nil
        hook = lambda { |_account, _request, context|
          received_context = context
          nil
        }
        allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

        initiate_passwordless_login!
        challenge = StandardId::CodeChallenge.last
        http_patch "/login_verify", params: { code: challenge.code.to_s }

        expect(received_context).to include(mechanism: "passwordless", provider: nil)
      end

      it "rejects sign-in when before_sign_in returns error hash on passwordless" do
        hook = ->(_account, _request, _context) { { error: "Passwordless denied" } }
        allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

        initiate_passwordless_login!
        challenge = StandardId::CodeChallenge.last
        http_patch "/login_verify", params: { code: challenge.code.to_s }

        expect(response).to redirect_to("/login")
        expect(flash[:alert]).to eq("Passwordless denied")
      end
    end

    # Note: New account creation via passwordless login is not tested here because
    # the dummy app's Account model requires `name`, which find_or_create_by_verified_email!
    # does not provide. The after_account_created hook is verified via social login
    # and signup tests which handle account creation with all required attributes.
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Password signup
  # ───────────────────────────────────────────────────────────────────────────
  describe "password signup" do
    it "calls after_account_created with mechanism: signup" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
      }
      allow(StandardId.config).to receive(:after_account_created).and_return(hook)

      http_post "/signup", params: { signup: { email: "new@example.com", password: "s3cureP@ss", password_confirmation: "s3cureP@ss" } }

      expect(received_context).to include(mechanism: "signup", provider: nil)
    end

    it "calls after_sign_in after signup" do
      sign_in_hook = instance_double(Proc)
      allow(sign_in_hook).to receive(:respond_to?).with(:call).and_return(true)
      allow(sign_in_hook).to receive(:call).and_return(nil)
      allow(StandardId.config).to receive(:after_sign_in).and_return(sign_in_hook)

      http_post "/signup", params: { signup: { email: "new2@example.com", password: "s3cureP@ss", password_confirmation: "s3cureP@ss" } }

      expect(sign_in_hook).to have_received(:call).with(
        an_instance_of(Account),
        an_instance_of(ActionDispatch::Request),
        hash_including(connection: "password", provider: nil, first_sign_in: true)
      )
    end

    it "uses redirect override from after_sign_in on signup" do
      hook = ->(_account, _request, _context) { "/setup-profile" }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/signup", params: { signup: { email: "new3@example.com", password: "s3cureP@ss", password_confirmation: "s3cureP@ss" } }

      expect(response).to redirect_to("/setup-profile")
    end

    it "rejects sign-in when after_sign_in raises AuthenticationDenied on signup" do
      hook = ->(_account, _request, _context) { raise StandardId::AuthenticationDenied, "Registration closed" }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/signup", params: { signup: { email: "new4@example.com", password: "s3cureP@ss", password_confirmation: "s3cureP@ss" } }

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to eq("Registration closed")
    end

    it "cleans up the account when AuthenticationDenied is raised during signup" do
      hook = ->(_account, _request, _context) { raise StandardId::AuthenticationDenied, "Not allowed" }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      expect {
        http_post "/signup", params: { signup: { email: "orphan@example.com", password: "s3cureP@ss", password_confirmation: "s3cureP@ss" } }
      }.not_to change(Account, :count)

      expect(Account.find_by(email: "orphan@example.com")).to be_nil
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Social login
  # ───────────────────────────────────────────────────────────────────────────
  describe "social login callback" do
    let(:state) { SecureRandom.urlsafe_base64(32) }
    let(:redirect_uri) { "/dashboard" }

    before do
      allow(StandardId.config).to receive(:account_class_name).and_return("Account")
      allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
      allow(StandardId.config).to receive(:google_client_secret).and_return("google-secret")
      allow(StandardId::Providers::Google).to receive(:get_user_info).and_return(
        {
          user_info: { "email" => "social@example.com", "name" => "Social User", "sub" => "prov_456" },
          tokens: { access_token: "token_456" }
        }.with_indifferent_access
      )

      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
        .to receive(:consume_oauth_request)
        .with(state)
        .and_return({ "params" => { "redirect_uri" => redirect_uri }, "nonce" => nil })
    end

    it "calls after_sign_in with connection: social and provider name" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

      expect(received_context[:connection]).to eq("social")
      expect(received_context[:provider]).to eq("google")
    end

    it "calls after_account_created for new social accounts" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
      }
      allow(StandardId.config).to receive(:after_account_created).and_return(hook)

      http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

      expect(received_context).to include(mechanism: "social", provider: "google")
    end

    it "does not call after_account_created for existing social accounts" do
      # Create existing account
      account = Account.create!(name: "Social User", email: "social@example.com")
      StandardId::EmailIdentifier.create!(account: account, value: "social@example.com", verified_at: Time.current)

      account_hook = instance_double(Proc)
      allow(account_hook).to receive(:respond_to?).with(:call).and_return(true)
      allow(account_hook).to receive(:call)
      allow(StandardId.config).to receive(:after_account_created).and_return(account_hook)

      http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

      expect(account_hook).not_to have_received(:call)
    end

    it "uses redirect override from after_sign_in hook" do
      hook = ->(_account, _request, _context) { "/social-onboarding" }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

      expect(response).to redirect_to("/social-onboarding")
    end

    it "rejects sign-in when after_sign_in raises AuthenticationDenied" do
      hook = ->(_account, _request, _context) { raise StandardId::AuthenticationDenied, "Social login denied" }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to eq("Social login denied")
    end

    it "cleans up the account when AuthenticationDenied is raised for a new social account" do
      hook = ->(_account, _request, _context) { raise StandardId::AuthenticationDenied, "Not allowed" }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      expect {
        http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }
      }.not_to change(Account, :count)

      expect(Account.find_by(email: "social@example.com")).to be_nil
    end

    it "calls before_sign_in with mechanism: social and provider" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

      expect(received_context).to include(mechanism: "social", provider: "google")
    end

    it "rejects social sign-in when before_sign_in returns error hash" do
      hook = ->(_account, _request, _context) { { error: "Social login blocked" } }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to eq("Social login blocked")
    end

    it "cleans up account when before_sign_in rejects a new social account" do
      hook = ->(_account, _request, _context) { { error: "Blocked" } }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      expect {
        http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }
      }.not_to change(Account, :count)

      expect(Account.find_by(email: "social@example.com")).to be_nil
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # AuthenticationDenied with blank message
  # ───────────────────────────────────────────────────────────────────────────
  describe "AuthenticationDenied with blank message" do
    before { create_account_with_password(email: email, password: password) }

    it "uses default message when AuthenticationDenied has no message" do
      hook = ->(_account, _request, _context) { raise StandardId::AuthenticationDenied }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      http_post "/login", params: { login: { email: email, password: password } }

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to eq("Sign-in was denied")
    end
  end
end
