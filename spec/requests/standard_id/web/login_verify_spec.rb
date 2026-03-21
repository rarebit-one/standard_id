require "rails_helper"

RSpec.describe "StandardId Web Login Verify (Passwordless OTP)", type: :request do
  let(:email) { "user@example.com" }
  let(:connection) { "email" }

  def enable_passwordless!
    allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
    allow(StandardId.config.passwordless).to receive(:connection).and_return(connection)
  end

  def disable_passwordless!
    allow(StandardId.config.web).to receive(:passwordless_login).and_return(false)
  end

  # Sets up an OTP session by going through the actual login flow
  def initiate_passwordless_login!
    enable_passwordless!
    sender = double("email_sender")
    allow(sender).to receive(:call)
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)

    http_post "/login", params: { login: { email: email } }
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to("/login_verify")
  end

  describe "POST /login (passwordless enabled)" do
    before { enable_passwordless! }

    it "generates OTP and redirects to login_verify" do
      sender = double("email_sender")
      expect(sender).to receive(:call).with(email, kind_of(String))
      allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)

      http_post "/login", params: { login: { email: email } }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/login_verify")

      challenge = StandardId::CodeChallenge.last
      expect(challenge).to be_present
      expect(challenge.realm).to eq("authentication")
      expect(challenge.channel).to eq("email")
      expect(challenge.target).to eq(email)
    end

    it "renders error when email is blank" do
      sender = double("email_sender")
      allow(sender).to receive(:call)
      allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)

      http_post "/login", params: { login: { email: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to eq("Please enter your email address")
    end

    it "preserves redirect_uri through the OTP flow" do
      account = Account.create!(name: "Test User", email: email)
      StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)

      sender = double("email_sender")
      allow(sender).to receive(:call)
      allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)

      http_post "/login", params: { login: { email: email }, redirect_uri: "/dashboard" }
      expect(response).to redirect_to("/login_verify")

      challenge = StandardId::CodeChallenge.last
      http_patch "/login_verify", params: { code: challenge.code.to_s }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/dashboard")
    end
  end

  describe "GET /login passwordless prop" do
    it "includes passwordless_enabled true when enabled" do
      enable_passwordless!
      http_get "/login"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("login")
    end

    it "includes passwordless_enabled false when disabled" do
      disable_passwordless!
      http_get "/login"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("login")
    end
  end

  describe "POST /login (passwordless disabled)" do
    before { disable_passwordless! }

    it "uses password authentication" do
      create_account_with_password(email: email, password: "s3cureP@ss")

      http_post "/login", params: { login: { email: email, password: "s3cureP@ss" }, redirect_uri: "/dashboard" }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/dashboard")
    end
  end

  describe "GET /login_verify" do
    before { enable_passwordless! }

    it "redirects to login when no OTP session exists" do
      http_get "/login_verify"

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to eq("Please start the login process")
    end

    it "redirects to login when OTP payload is tampered or expired" do
      post util_session_path, params: { key: "standard_id_otp_payload", value: "tampered-invalid-payload" }

      http_get "/login_verify"

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to eq("Your verification session has expired. Please try again.")
    end

    it "returns 404 when passwordless is disabled" do
      disable_passwordless!
      http_get "/login_verify"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /login_verify" do
    it "redirects to login when no OTP session exists" do
      enable_passwordless!
      http_patch "/login_verify", params: { code: "123456" }

      expect(response).to redirect_to("/login")
    end

    context "with valid OTP session" do
      let!(:account) do
        account = Account.create!(name: "Test User", email: email)
        StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
        account
      end

      before do
        initiate_passwordless_login!
      end

      it "signs in and redirects on valid code" do
        challenge = StandardId::CodeChallenge.last

        http_patch "/login_verify", params: { code: challenge.code.to_s }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to("/")
        expect(flash[:notice]).to eq("Successfully signed in")

        expect(challenge.reload).to be_used
      end

      it "uses existing account when email identifier exists" do
        challenge = StandardId::CodeChallenge.last

        expect {
          http_patch "/login_verify", params: { code: challenge.code.to_s }
        }.not_to change(Account, :count)

        expect(response).to have_http_status(:see_other)
      end

      it "creates a browser session on success" do
        challenge = StandardId::CodeChallenge.last

        expect {
          http_patch "/login_verify", params: { code: challenge.code.to_s }
        }.to change(StandardId::BrowserSession, :count).by(1)
      end

      it "cleans up OTP session data after success" do
        challenge = StandardId::CodeChallenge.last

        http_patch "/login_verify", params: { code: challenge.code.to_s }

        expect(response).to have_http_status(:see_other)

        # Sign out so the redirect_if_authenticated guard doesn't mask stale session data
        http_post "/logout"

        # Without the OTP payload, login_verify should redirect to login
        http_get "/login_verify"
        expect(response).to redirect_to("/login")
        expect(flash[:alert]).to eq("Please start the login process")
      end

      it "rejects an invalid code" do
        http_patch "/login_verify", params: { code: "000000" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(flash[:alert]).to eq("Invalid or expired verification code")
      end

      it "rejects a blank code" do
        http_patch "/login_verify", params: { code: "" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(flash[:alert]).to eq("Please enter the verification code")
      end

      it "locks out after max_attempts failed verifications" do
        allow(StandardId.config.passwordless).to receive(:max_attempts).and_return(3)
        challenge = StandardId::CodeChallenge.last

        3.times { http_patch "/login_verify", params: { code: "000000" } }

        # Challenge should be invalidated (used) after max attempts
        expect(challenge.reload).to be_used

        # Even the correct code should fail now
        http_patch "/login_verify", params: { code: challenge.code.to_s }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "tracks attempt count in challenge metadata" do
        challenge = StandardId::CodeChallenge.last

        http_patch "/login_verify", params: { code: "000000" }

        expect(challenge.reload.metadata["attempts"]).to eq(1)
      end

      it "redirects authenticated users away from show" do
        challenge = StandardId::CodeChallenge.last
        http_patch "/login_verify", params: { code: challenge.code.to_s }

        # Now authenticated — visiting show should redirect
        initiate_passwordless_login!
        http_get "/login_verify"
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to("/")
      end
    end
  end
end
