require "rails_helper"

RSpec.describe StandardId::Api::AuthorizationController, type: :controller do
  routes { StandardId::ApiEngine.routes }

  let(:client_credential) do
    StandardId::ClientSecretCredential.create!(
      name: "Test Client",
      client_id: "test_client_123",
      client_secret: "test_secret",
      redirect_uris: "https://example.com/callback https://app.example.com/auth",
      scopes: "read write",
      active: true
    )
  end

  before do
    # Create the associated credential record
    account = create_account
    identifier = StandardId::EmailIdentifier.create!(
      account: account,
      value: "client@example.com",
      verified_at: Time.current
    )

    StandardId::Credential.create!(
      credentialable: client_credential,
      identifier: identifier
    )
  end

  describe "GET #show" do
    context "with Authorization Code Flow (response_type=code)" do
      let(:valid_params) do
        {
          response_type: "code",
          client_id: client_credential.client_id,
          audience: "https://api.example.com",
          redirect_uri: "https://example.com/callback",
          scope: "read",
          state: "random_state_123"
        }
      end

      it "redirects with authorization code" do
        get :show, params: valid_params

        expect(response).to have_http_status(:found)
        expect(response.location).to include("code=")
        expect(response.location).to include("state=random_state_123")
        expect(response.location).to start_with("https://example.com/callback")
      end

      it "requires response_type parameter" do
        get :show, params: valid_params.except(:response_type)
        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to include("The response_type parameter is required")
      end

      it "requires client_id parameter" do
        get :show, params: valid_params.except(:client_id)
        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to include("The client_id parameter is required")
      end

      it "requires audience parameter" do
        get :show, params: valid_params.except(:audience)
        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to include("The audience parameter is required")
      end

      it "validates client_id exists" do
        get :show, params: valid_params.merge(client_id: "invalid_client")
        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
        expect(body["error_description"]).to include("Invalid client_id")
      end
    end

    context "with Implicit Flow (response_type=token)" do
      let(:valid_params) do
        {
          response_type: "token",
          client_id: client_credential.client_id,
          redirect_uri: "https://example.com/callback",
          scope: "read",
          state: "random_state_456"
        }
      end

      context "when not authenticated" do
        it "redirects to login page" do
          get :show, params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("/login")
          expect(response.location).to include("redirect_uri=")
        end
      end

      context "when authenticated" do
        let(:authenticated_account) { create_account }

        before do
          # Mock authentication by overriding current_account
          allow(controller).to receive(:current_account).and_return(authenticated_account)
        end

        it "redirects with access token in fragment" do
          get :show, params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("#access_token=")
          expect(response.location).to include("token_type=Bearer")
          expect(response.location).to include("state=random_state_456")
          expect(response.location).to start_with("https://example.com/callback")
        end

        it "requires client_id parameter" do
          get :show, params: valid_params.except(:client_id)
          expect(response).to have_http_status(:bad_request)
          body = JSON.parse(response.body)
          expect(body["error"]).to eq("invalid_request")
          expect(body["error_description"]).to include("The client_id parameter is required")
        end
      end
    end

    context "with Implicit Flow including ID token (response_type=token id_token)" do
      let(:valid_params) do
        {
          response_type: "token id_token",
          client_id: client_credential.client_id,
          redirect_uri: "https://example.com/callback",
          nonce: "test_nonce_789"
        }
      end

      context "when not authenticated" do
        it "redirects to login page" do
          get :show, params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("/login")
          expect(response.location).to include("redirect_uri=")
        end
      end

      context "when authenticated" do
        let(:authenticated_account) { create_account }

        before do
          # Mock authentication by overriding current_account
          allow(controller).to receive(:current_account).and_return(authenticated_account)
        end

        it "redirects with both access token and ID token in fragment" do
          get :show, params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("#access_token=")
          expect(response.location).to include("id_token=")
          expect(response.location).to include("token_type=Bearer")
        end
      end
    end

    context "with unsupported response_type" do
      it "returns error response for unsupported response_type" do
        get :show, params: {
          response_type: "unsupported",
          client_id: client_credential.client_id
        }
        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("unsupported_response_type")
        expect(body["error_description"]).to include("Unsupported response_type")
      end
    end
  end

  private

  def create_account
    Account.create!(
      name: "Test Client Account",
      email: "client-#{SecureRandom.hex(4)}@example.com"
    )
  end
end
