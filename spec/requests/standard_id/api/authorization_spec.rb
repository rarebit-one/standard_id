require "rails_helper"

RSpec.describe "StandardId API Authorization", type: :request do
  let(:client_account) { Account.create!(name: "Test Client Account", email: "client-#{SecureRandom.hex(4)}@example.com") }
  let(:client) do
    StandardId::ClientApplication.create!(
      owner: client_account,
      name: "Test Client",
      client_id: "test_client_123",
      redirect_uris: "https://example.com/callback https://app.example.com/auth",
      scopes: "read write",
      # Consent is exercised in its own spec (api/consent_spec.rb). These cases
      # assert direct code issuance / validation, so opt this client out of the
      # consent gate.
      require_consent: false
    )
  end
  let(:client_credential) do
    client.create_client_secret!(
      name: "Test Client Secret",
      client_secret: "test_secret"
    )
  end

  before do
    # Create the associated credential record via identifier
    identifier = StandardId::EmailIdentifier.create!(
      account: client_account,
      value: "client@example.com",
      verified_at: Time.current
    )

    StandardId::Credential.create!(
      credentialable: client_credential,
      identifier: identifier
    )
  end

  describe "GET /api/authorize" do
    context "with Authorization Code Flow (response_type=code)" do
      let(:pkce_verifier) { "a-very-long-random-verifier-#{SecureRandom.hex(16)}" }
      let(:pkce_challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(pkce_verifier)).delete("=") }
      let(:valid_params) do
        {
          response_type: "code",
          client_id: client.client_id,
          audience: "https://api.example.com",
          redirect_uri: "https://example.com/callback",
          scope: "read",
          state: "random_state_123",
          code_challenge: pkce_challenge,
          code_challenge_method: "S256"
        }
      end

      context "when not authenticated" do
        it "redirects to login page" do
          http_get "/api/authorize", params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("/login")
          expect(response.location).to include("redirect_uri=")
        end
      end

      context "when authenticated" do
        let(:authenticated_account) { Account.create!(name: "Auth Code User", email: "auth-code@example.com") }

        before do
          browser_session = StandardId::BrowserSession.create!(account: authenticated_account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 1.day.from_now)
          post util_session_path, params: { session_token: browser_session.token }
        end

        it "redirects with authorization code" do
          http_get "/api/authorize", params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("code=")
          expect(response.location).to include("state=random_state_123")
          expect(response.location).to start_with("https://example.com/callback")
        end

        it "requires client_id parameter" do
          http_get "/api/authorize", params: valid_params.except(:client_id)
          expect(response).to have_http_status(:bad_request)
          body = json_body
          expect(body["error"]).to eq("invalid_request")
          expect(body["error_description"]).to include("The client_id parameter is required")
        end

        it "issues a code when audience is omitted (audience is optional)" do
          http_get "/api/authorize", params: valid_params.except(:audience)
          expect(response).to have_http_status(:found)
          expect(response.location).to include("code=")
          expect(response.location).to include("state=random_state_123")
          expect(response.location).to start_with("https://example.com/callback")
        end

        it "validates client_id exists" do
          http_get "/api/authorize", params: valid_params.merge(client_id: "invalid_client")
          expect(response).to have_http_status(:unauthorized)
          body = json_body
          expect(body["error"]).to eq("invalid_client")
          expect(body["error_description"]).to include("Invalid client_id")
        end

        context "PKCE enforcement" do
          it "rejects requests without code_challenge when client.require_pkce is true" do
            http_get "/api/authorize", params: valid_params.except(:code_challenge, :code_challenge_method)
            expect(response).to have_http_status(:bad_request)
            body = json_body
            expect(body["error"]).to eq("invalid_request")
            expect(body["error_description"]).to include("code_challenge is required for this client")
          end

          it "rejects requests with non-S256 code_challenge_method" do
            http_get "/api/authorize", params: valid_params.merge(code_challenge_method: "plain")
            expect(response).to have_http_status(:bad_request)
            body = json_body
            expect(body["error"]).to eq("invalid_request")
            expect(body["error_description"]).to include("only S256 is allowed")
          end

          context "when client opts out of PKCE" do
            before { client.update!(require_pkce: false, code_challenge_methods: nil) }

            it "accepts requests without code_challenge" do
              http_get "/api/authorize", params: valid_params.except(:code_challenge, :code_challenge_method)
              expect(response).to have_http_status(:found)
              expect(response.location).to include("code=")
            end

            it "still accepts a valid S256 code_challenge if supplied" do
              http_get "/api/authorize", params: valid_params
              expect(response).to have_http_status(:found)
              expect(response.location).to include("code=")
            end
          end

          context "for a public client with a loopback redirect (RFC 8252 §7.3)" do
            let(:loopback_client) do
              StandardId::ClientApplication.create!(
                owner: client_account,
                name: "Native Loopback Client",
                client_id: "native_loopback_123",
                redirect_uris: "http://127.0.0.1/callback",
                scopes: "read write",
                client_type: "public",
                require_pkce: true,
                code_challenge_methods: "S256",
                require_consent: false
              )
            end

            it "issues a code to a loopback redirect_uri on an ephemeral port" do
              http_get "/api/authorize", params: valid_params.merge(
                client_id: loopback_client.client_id,
                redirect_uri: "http://127.0.0.1:53682/callback"
              )

              expect(response).to have_http_status(:found)
              expect(response.location).to include("code=")
              expect(response.location).to include("state=random_state_123")
              expect(response.location).to start_with("http://127.0.0.1:53682/callback")
            end

            it "rejects a loopback redirect_uri with a different path" do
              http_get "/api/authorize", params: valid_params.merge(
                client_id: loopback_client.client_id,
                redirect_uri: "http://127.0.0.1:53682/callback/evil"
              )

              expect(response).to have_http_status(:bad_request)
              expect(json_body["error"]).to eq("invalid_request")
            end
          end

          context "for a public client" do
            before { client.update!(client_type: "public") }

            it "accepts requests with a valid S256 code_challenge" do
              http_get "/api/authorize", params: valid_params
              expect(response).to have_http_status(:found)
              expect(response.location).to include("code=")
            end

            it "rejects requests without a code_challenge" do
              http_get "/api/authorize", params: valid_params.except(:code_challenge, :code_challenge_method)
              expect(response).to have_http_status(:bad_request)
              body = json_body
              expect(body["error"]).to eq("invalid_request")
              expect(body["error_description"]).to include("code_challenge is required for this client")
            end

            it "rejects requests with non-S256 code_challenge_method" do
              http_get "/api/authorize", params: valid_params.merge(code_challenge_method: "plain")
              expect(response).to have_http_status(:bad_request)
            end
          end
        end
      end

      it "requires response_type parameter" do
        http_get "/api/authorize", params: valid_params.except(:response_type)
        expect(response).to have_http_status(:bad_request)
        body = json_body
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to include("The response_type parameter is required")
      end
    end

    context "with Implicit Flow (response_type=token)" do
      let(:valid_params) do
        {
          response_type: "token",
          client_id: client.client_id,
          redirect_uri: "https://example.com/callback",
          scope: "read",
          state: "random_state_456"
        }
      end

      context "when not authenticated" do
        it "redirects to login page" do
          http_get "/api/authorize", params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("/login")
          expect(response.location).to include("redirect_uri=")
        end
      end

      context "when authenticated" do
        let(:authenticated_account) { Account.create!(name: "Auth", email: "auth@example.com") }

        before do
          browser_session = StandardId::BrowserSession.create!(account: authenticated_account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 1.day.from_now)
          post util_session_path, params: { session_token: browser_session.token }
        end

        it "redirects with access token in fragment" do
          http_get "/api/authorize", params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("#access_token=")
          expect(response.location).to include("token_type=Bearer")
          expect(response.location).to include("state=random_state_456")
          expect(response.location).to start_with("https://example.com/callback")
        end

        it "requires client_id parameter" do
          http_get "/api/authorize", params: valid_params.except(:client_id)
          expect(response).to have_http_status(:bad_request)
          body = json_body
          expect(body["error"]).to eq("invalid_request")
          expect(body["error_description"]).to include("The client_id parameter is required")
        end
      end
    end

    context "with Implicit Flow including ID token (response_type=token id_token)" do
      let(:valid_params) do
        {
          response_type: "token id_token",
          client_id: client.client_id,
          redirect_uri: "https://example.com/callback",
          nonce: "test_nonce_789"
        }
      end

      context "when not authenticated" do
        it "redirects to login page" do
          http_get "/api/authorize", params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("/login")
          expect(response.location).to include("redirect_uri=")
        end
      end

      context "when authenticated" do
        let(:authenticated_account) { Account.create!(name: "Auth2", email: "auth2@example.com") }

        before do
          browser_session = StandardId::BrowserSession.create!(account: authenticated_account, ip_address: "127.0.0.1", user_agent: "RSpec", expires_at: 1.day.from_now)
          post util_session_path, params: { session_token: browser_session.token }
        end

        it "redirects with both access token and ID token in fragment" do
          http_get "/api/authorize", params: valid_params

          expect(response).to have_http_status(:found)
          expect(response.location).to include("#access_token=")
          expect(response.location).to include("id_token=")
          expect(response.location).to include("token_type=Bearer")
        end
      end
    end

    context "with unsupported response_type" do
      it "returns error response for unsupported response_type" do
        http_get "/api/authorize", params: { response_type: "unsupported", client_id: client.client_id }

        expect(response).to have_http_status(:bad_request)
        body = json_body
        expect(body["error"]).to eq("unsupported_response_type")
        expect(body["error_description"]).to include("Unsupported response_type")
      end
    end
  end
end
