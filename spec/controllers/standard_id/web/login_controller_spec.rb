require "rails_helper"

RSpec.describe StandardId::Web::LoginController, type: :controller do
  routes { StandardId::WebEngine.routes }

  let(:email) { "user@example.com" }
  let(:password) { "s3cureP@ss" }

  def create_account_with_password(email:, password:)
    account = Account.create!(name: "Test User", email: email)
    identifier = StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
    password_credential = StandardId::PasswordCredential.create!(login: email, password: password)
    StandardId::Credential.create!(credentialable: password_credential, identifier: identifier)
    account
  end

  describe "GET #show" do
    context "when not authenticated" do
      it "renders the login page" do
        get :show, params: { redirect_uri: "/dashboard" }

        expect(response).to have_http_status(:ok)
      end
    end

    context "when already authenticated" do
      it "redirects to after_authentication_url" do
        account = Account.create!(name: "Auth'd", email: "authd@example.com")
        allow(controller).to receive(:current_account).and_return(account)

        get :show

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/")
      end
    end
  end

  describe "POST #create" do
    context "when social login connection is present" do
      it "redirects to social login URL with connection param" do
        # Define the method dynamically to satisfy verifying partial doubles
        StandardId.config.define_singleton_method(:default_client_id) { "web_client" }
        allow(controller).to receive(:callback_url).and_return("/auth/callback/google")

        post :create, params: { connection: "google-oauth2", redirect_uri: "/after" }

        expect(response).to have_http_status(:found)
        expect(response.location).to start_with("http://test.host/api/authorize?")
        expect(response.location).to include("connection=google-oauth2")
        expect(response.location).to include("client_id=web_client")
      end
    end

    context "when password login is attempted" do
      it "signs in and redirects on valid credentials" do
        create_account_with_password(email: email, password: password)

        post :create, params: { login: { email: email, password: password }, redirect_uri: "/after" }

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to("/after")
      end

      it "renders the form with error on invalid credentials" do
        create_account_with_password(email: email, password: password)

        post :create, params: { login: { email: email, password: "wrong" } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(flash[:alert]).to eq("Invalid email or password")
      end

      it "sets remember_token cookie when remember_me is checked" do
        create_account_with_password(email: email, password: password)

        post :create, params: { login: { email: email, password: password, remember_me: "1" }, redirect_uri: "/after" }

        expect(response).to have_http_status(:found)
        expect(cookies["remember_token"]).to be_present
      end

      it "does not set remember_token cookie when remember_me is not checked" do
        create_account_with_password(email: email, password: password)

        post :create, params: { login: { email: email, password: password, remember_me: "0" }, redirect_uri: "/after" }

        expect(response).to have_http_status(:found)
        expect(cookies["remember_token"]).to be_blank
      end
    end
  end
end
