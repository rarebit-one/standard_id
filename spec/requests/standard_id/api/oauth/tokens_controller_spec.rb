require "rails_helper"

RSpec.describe "StandardId::Api::Oauth::TokensController", type: :request do
  # routes { StandardId::ApiEngine.routes }

  # let(:path) { "/api/oauth/token" }
  let(:path) { api_standard_id_api.oauth_token_path }

  describe "POST /api/oauth/token" do
    describe "error handling" do
      it "returns error when grant_type is missing" do
        post path, params: {}, as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to eq("The grant_type parameter is required")
      end

      it "returns error for unsupported grant_type" do
        post path, params: { grant_type: "unsupported_grant" }, as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("unsupported_grant_type")
        expect(body["error_description"]).to eq("Unsupported grant_type: unsupported_grant")
      end

      it "accepts application/x-www-form-urlencoded per RFC 6749" do
        post path, params: { grant_type: "client_credentials", client_id: "test", client_secret: "test", audience: "test" },
          headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

        # Should fail on invalid client, not content type
        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end

      it "accepts vendor-specific JSON content types" do
        post path, params: {}, headers: { "CONTENT_TYPE" => "application/vnd.api+json" }

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to eq("The grant_type parameter is required")
      end
    end

    describe "HTTP Basic client authentication" do
      def basic_auth_header(client_id, client_secret)
        encoded = Base64.strict_encode64("#{client_id}:#{client_secret}")
        { "Authorization" => "Basic #{encoded}" }
      end

      let(:client_account) { Account.create!(name: "Test Client Account", email: "client-#{SecureRandom.hex(4)}@example.com") }
      let(:client_secret_value) { "test_secret_#{SecureRandom.hex(8)}" }
      let(:client_app) do
        StandardId::ClientApplication.create!(
          owner: client_account,
          name: "Test Client",
          redirect_uris: "https://example.com/callback",
          scopes: "read write",
          grant_types: "client_credentials authorization_code"
        )
      end
      let(:client_credential) do
        client_app.create_client_secret!(
          name: "Test Client Secret",
          client_secret: client_secret_value
        )
      end

      before do
        identifier = StandardId::EmailIdentifier.create!(
          account: client_account,
          value: "client-cred-#{SecureRandom.hex(4)}@example.com",
          verified_at: Time.current
        )
        StandardId::Credential.create!(
          credentialable: client_credential,
          identifier: identifier
        )
      end

      it "successfully authenticates via Basic auth header" do
        post path,
          params: { grant_type: "client_credentials", audience: "test" },
          headers: basic_auth_header(client_app.client_id, client_secret_value),
          as: :json

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["access_token"]).to be_present
        expect(body["token_type"]).to eq("Bearer")
        expect(body["expires_in"]).to be > 0
      end

      it "successfully authenticates via request body" do
        post path,
          params: {
            grant_type: "client_credentials",
            client_id: client_app.client_id,
            client_secret: client_secret_value,
            audience: "test"
          },
          as: :json

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["access_token"]).to be_present
        expect(body["token_type"]).to eq("Bearer")
        expect(body["expires_in"]).to be > 0
      end

      it "returns invalid_client for wrong credentials via Basic auth" do
        post path,
          params: { grant_type: "client_credentials", audience: "test" },
          headers: basic_auth_header(client_app.client_id, "wrong-secret"),
          as: :json

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end

      it "rejects when credentials are in both header and body" do
        post path,
          params: { grant_type: "client_credentials", client_id: client_app.client_id, client_secret: client_secret_value },
          headers: basic_auth_header(client_app.client_id, client_secret_value),
          as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
        expect(body["error_description"]).to include("Authorization header OR request body")
      end

      it "rejects malformed Basic auth encoding" do
        post path,
          params: { grant_type: "client_credentials" },
          headers: { "Authorization" => "Basic !!!invalid-base64!!!" },
          as: :json

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end

      it "URL-decodes client credentials per RFC 6749 Section 2.3.1" do
        # Client ID with special chars: "my:client" → URL-encoded as "my%3Aclient"
        encoded_id = CGI.escape("my:client")
        encoded_secret = CGI.escape("secret/with+special=chars")

        post path,
          params: { grant_type: "client_credentials", audience: "test" },
          headers: basic_auth_header(encoded_id, encoded_secret),
          as: :json

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end

      it "ignores non-Basic Authorization headers" do
        post path,
          params: { grant_type: "client_credentials" },
          headers: { "Authorization" => "Bearer some-token" },
          as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_request")
      end

      it "handles client_secret containing colons" do
        # Secret "pass:word:123" should be split on first colon only
        post path,
          params: { grant_type: "client_credentials", audience: "test" },
          headers: basic_auth_header("my-client", "pass:word:123"),
          as: :json

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("invalid_client")
      end
    end

    describe "authorization_code grant" do
      include ActiveSupport::Testing::TimeHelpers

      let(:account) { Account.create!(name: "Auth Code User", email: "authcode-#{SecureRandom.hex(4)}@example.com") }
      let(:redirect_uri) { "https://app.example.com/callback" }
      let(:code_verifier) { "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" }

      # base64url(SHA256(verifier)) — the S256 code_challenge per RFC 7636.
      def s256_challenge(verifier)
        Base64.urlsafe_encode64(Digest::SHA256.digest(verifier)).delete("=")
      end

      # `redirect_uri:` defaults to the group's let; pass an explicit value to
      # issue a code bound to a different redirect (e.g. a loopback URI with
      # an ephemeral port, mirroring what the authorize endpoint stores).
      def issue_code!(client_id:, with_challenge: true, plaintext_code: SecureRandom.hex(20), redirect_uri: nil)
        redirect_uri ||= self.redirect_uri
        StandardId::AuthorizationCode.issue!(
          plaintext_code: plaintext_code,
          client_id: client_id,
          redirect_uri: redirect_uri,
          scope: "openid profile",
          account: account,
          code_challenge: with_challenge ? s256_challenge(code_verifier) : nil,
          code_challenge_method: with_challenge ? "S256" : nil
        )
        plaintext_code
      end

      describe "public client (PKCE, no client_secret)" do
        let(:public_client) do
          StandardId::ClientApplication.create!(
            owner: account,
            name: "Public Client",
            redirect_uris: redirect_uri,
            scopes: "openid profile email",
            grant_types: "authorization_code refresh_token",
            response_types: "code",
            client_type: "public",
            require_pkce: true,
            code_challenge_methods: "S256"
          )
        end

        it "issues access + refresh tokens with a valid code_verifier and no secret" do
          code = issue_code!(client_id: public_client.client_id)

          post path,
            params: {
              grant_type: "authorization_code",
              client_id: public_client.client_id,
              code: code,
              redirect_uri: redirect_uri,
              code_verifier: code_verifier
            },
            as: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body["access_token"]).to be_present
          expect(body["token_type"]).to eq("Bearer")
          expect(body["refresh_token"]).to be_present
        end

        it "rejects a wrong code_verifier with invalid_grant" do
          code = issue_code!(client_id: public_client.client_id)

          post path,
            params: {
              grant_type: "authorization_code",
              client_id: public_client.client_id,
              code: code,
              redirect_uri: redirect_uri,
              code_verifier: "totally-wrong-verifier"
            },
            as: :json

          expect(response).to have_http_status(:bad_request)
          expect(JSON.parse(response.body)["error"]).to eq("invalid_grant")
        end

        it "rejects a public client that sends a client_secret" do
          code = issue_code!(client_id: public_client.client_id)

          post path,
            params: {
              grant_type: "authorization_code",
              client_id: public_client.client_id,
              client_secret: "should-not-be-here",
              code: code,
              redirect_uri: redirect_uri,
              code_verifier: code_verifier
            },
            as: :json

          expect(response).to have_http_status(:unauthorized)
          expect(JSON.parse(response.body)["error"]).to eq("invalid_client")
        end
      end

      describe "confidential client (regression)" do
        let(:client_secret_value) { "conf_secret_#{SecureRandom.hex(8)}" }
        let(:confidential_client) do
          client = StandardId::ClientApplication.create!(
            owner: account,
            name: "Confidential Client",
            redirect_uris: redirect_uri,
            scopes: "openid profile email",
            grant_types: "authorization_code refresh_token",
            response_types: "code",
            client_type: "confidential",
            require_pkce: false,
            code_challenge_methods: "S256"
          )
          client.create_client_secret!(name: "Secret", client_secret: client_secret_value)
          client
        end

        it "still exchanges a code for tokens with a valid client_secret (no PKCE)" do
          code = issue_code!(client_id: confidential_client.client_id, with_challenge: false)

          post path,
            params: {
              grant_type: "authorization_code",
              client_id: confidential_client.client_id,
              client_secret: client_secret_value,
              code: code,
              redirect_uri: redirect_uri
            },
            as: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body["access_token"]).to be_present
          expect(body["refresh_token"]).to be_present
        end

        it "rejects a confidential client presenting a wrong secret" do
          code = issue_code!(client_id: confidential_client.client_id, with_challenge: false)

          post path,
            params: {
              grant_type: "authorization_code",
              client_id: confidential_client.client_id,
              client_secret: "wrong",
              code: code,
              redirect_uri: redirect_uri
            },
            as: :json

          expect(response).to have_http_status(:unauthorized)
          expect(JSON.parse(response.body)["error"]).to eq("invalid_client")
        end
      end

      # RFC 8252 §7.3 relaxes redirect_uri matching at *authorize* time for
      # loopback URIs (any port may be requested). At *token* time, however,
      # the flow compares the redirect_uri param against the exact string the
      # code was issued with (lib/standard_id/oauth/authorization_code_flow.rb)
      # — so the ephemeral port chosen at authorization time must be echoed
      # back verbatim in the token exchange.
      describe "loopback redirect_uri consistency at token time (RFC 8252 §7.3)" do
        let(:registered_loopback_uri) { "http://127.0.0.1/callback" }
        let(:authorize_time_redirect_uri) { "http://127.0.0.1:53682/callback" }

        let(:loopback_client) do
          StandardId::ClientApplication.create!(
            owner: account,
            name: "Native Loopback Client",
            redirect_uris: registered_loopback_uri,
            scopes: "openid profile email",
            grant_types: "authorization_code refresh_token",
            response_types: "code",
            client_type: "public",
            require_pkce: true,
            code_challenge_methods: "S256"
          )
        end

        def exchange_params(code, redirect_uri)
          {
            grant_type: "authorization_code",
            client_id: loopback_client.client_id,
            code: code,
            redirect_uri: redirect_uri,
            code_verifier: code_verifier
          }.compact
        end

        it "succeeds when the token request echoes the same ephemeral port used at authorize time" do
          code = issue_code!(client_id: loopback_client.client_id, redirect_uri: authorize_time_redirect_uri)

          post path, params: exchange_params(code, authorize_time_redirect_uri), as: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body["access_token"]).to be_present
          expect(body["refresh_token"]).to be_present
        end

        it "rejects a different loopback port at token time with invalid_grant" do
          code = issue_code!(client_id: loopback_client.client_id, redirect_uri: authorize_time_redirect_uri)

          post path, params: exchange_params(code, "http://127.0.0.1:53683/callback"), as: :json

          expect(response).to have_http_status(:bad_request)
          body = JSON.parse(response.body)
          expect(body["error"]).to eq("invalid_grant")
          expect(body["error_description"]).to eq("Redirect URI mismatch")
        end

        # CURRENT (lenient) behavior, pinned deliberately: the flow only
        # compares redirect_uri when the param is present
        # (`params[:redirect_uri].present? && ...` in
        # lib/standard_id/oauth/authorization_code_flow.rb), so omitting it
        # skips the check entirely and the exchange succeeds. RFC 6749 §4.1.3
        # says redirect_uri is REQUIRED at token time when it was included in
        # the authorization request — tightening this to fail closed is
        # tracked separately; this example exists so any future change is a
        # conscious one.
        it "currently succeeds when redirect_uri is omitted at token time (lenient; RFC 6749 §4.1.3 would require it)" do
          code = issue_code!(client_id: loopback_client.client_id, redirect_uri: authorize_time_redirect_uri)

          post path, params: exchange_params(code, nil), as: :json

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["access_token"]).to be_present
        end
      end

      describe "authorization code replay" do
        let(:public_client) do
          StandardId::ClientApplication.create!(
            owner: account,
            name: "Replay Client",
            redirect_uris: redirect_uri,
            scopes: "openid profile email",
            grant_types: "authorization_code refresh_token",
            response_types: "code",
            client_type: "public",
            require_pkce: true,
            code_challenge_methods: "S256"
          )
        end

        def exchange!(code)
          post path,
            params: {
              grant_type: "authorization_code",
              client_id: public_client.client_id,
              code: code,
              redirect_uri: redirect_uri,
              code_verifier: code_verifier
            },
            as: :json
        end

        it "rejects the second redemption of the same code and mints no second token" do
          code = issue_code!(client_id: public_client.client_id)

          exchange!(code)
          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["access_token"]).to be_present

          expect { exchange!(code) }.not_to change(StandardId::RefreshToken, :count)

          expect(response).to have_http_status(:bad_request)
          body = JSON.parse(response.body)
          expect(body["error"]).to eq("invalid_grant")
          expect(body["error_description"]).to eq("Invalid or expired authorization code")
          expect(body["access_token"]).to be_nil
        end
      end

      describe "expired authorization code" do
        let(:public_client) do
          StandardId::ClientApplication.create!(
            owner: account,
            name: "Expiry Client",
            redirect_uris: redirect_uri,
            scopes: "openid profile email",
            grant_types: "authorization_code refresh_token",
            response_types: "code",
            client_type: "public",
            require_pkce: true,
            code_challenge_methods: "S256"
          )
        end

        it "rejects a code past its TTL with invalid_grant" do
          code = issue_code!(client_id: public_client.client_id)

          travel StandardId::AuthorizationCode.default_ttl + 1.second do
            post path,
              params: {
                grant_type: "authorization_code",
                client_id: public_client.client_id,
                code: code,
                redirect_uri: redirect_uri,
                code_verifier: code_verifier
              },
              as: :json
          end

          expect(response).to have_http_status(:bad_request)
          body = JSON.parse(response.body)
          expect(body["error"]).to eq("invalid_grant")
          expect(body["error_description"]).to eq("Invalid or expired authorization code")
        end
      end

      describe "plain PKCE method at redemption time" do
        let(:public_client) do
          StandardId::ClientApplication.create!(
            owner: account,
            name: "Plain PKCE Client",
            redirect_uris: redirect_uri,
            scopes: "openid profile email",
            grant_types: "authorization_code refresh_token",
            response_types: "code",
            client_type: "public",
            require_pkce: true,
            code_challenge_methods: "S256"
          )
        end

        # AuthorizationCode.issue! fails fast on non-S256 methods, so a
        # "plain" code can only exist via direct persistence (legacy data or
        # a bypassed issuance path). Redemption must still fail closed:
        # pkce_valid? only accepts S256 (OAuth 2.1 drops "plain" because it
        # transmits the verifier in cleartext).
        it "rejects a stored code with code_challenge_method=plain even when the verifier matches" do
          code = SecureRandom.hex(20)
          # With the "plain" method the challenge IS the verifier; mirror the
          # storage format (SHA256 of the challenge, per RAR-58).
          StandardId::AuthorizationCode.create!(
            account: account,
            code_hash: StandardId::AuthorizationCode.hash_for(code),
            client_id: public_client.client_id,
            redirect_uri: redirect_uri,
            scope: "openid profile",
            code_challenge: Digest::SHA256.hexdigest(code_verifier),
            code_challenge_method: "plain",
            issued_at: Time.current,
            expires_at: 10.minutes.from_now
          )

          post path,
            params: {
              grant_type: "authorization_code",
              client_id: public_client.client_id,
              code: code,
              redirect_uri: redirect_uri,
              code_verifier: code_verifier
            },
            as: :json

          expect(response).to have_http_status(:bad_request)
          body = JSON.parse(response.body)
          expect(body["error"]).to eq("invalid_grant")
          expect(body["error_description"]).to eq("Invalid PKCE code_verifier")
        end
      end

      # Nested here so it can bootstrap real refresh tokens through the
      # authorization_code exchange helpers above.
      describe "refresh_token grant (full HTTP round-trip)" do
        let(:public_client) do
          StandardId::ClientApplication.create!(
            owner: account,
            name: "Refresh Client",
            redirect_uris: redirect_uri,
            scopes: "openid profile email",
            grant_types: "authorization_code refresh_token",
            response_types: "code",
            client_type: "public",
            require_pkce: true,
            code_challenge_methods: "S256"
          )
        end

        def obtain_initial_tokens!
          code = issue_code!(client_id: public_client.client_id)
          post path,
            params: {
              grant_type: "authorization_code",
              client_id: public_client.client_id,
              code: code,
              redirect_uri: redirect_uri,
              code_verifier: code_verifier
            },
            as: :json
          expect(response).to have_http_status(:ok)
          JSON.parse(response.body)
        end

        def refresh!(refresh_token)
          post path,
            params: {
              grant_type: "refresh_token",
              client_id: public_client.client_id,
              refresh_token: refresh_token
            },
            as: :json
        end

        def record_for(refresh_token)
          jti = StandardId::JwtService.decode(refresh_token)[:jti]
          StandardId::RefreshToken.find_by_jti(jti)
        end

        it "rotates the refresh token: new access + refresh tokens, old record revoked and chained" do
          initial = obtain_initial_tokens!
          old_refresh_token = initial["refresh_token"]
          old_record = record_for(old_refresh_token)

          refresh!(old_refresh_token)

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body["access_token"]).to be_present
          expect(body["access_token"]).not_to eq(initial["access_token"])
          expect(body["refresh_token"]).to be_present
          expect(body["refresh_token"]).not_to eq(old_refresh_token)

          # Rotation revokes the old record and links the new one to it,
          # forming the family chain used for reuse detection.
          expect(old_record.reload.revoked?).to be true
          new_record = record_for(body["refresh_token"])
          expect(new_record).to be_present
          expect(new_record.revoked?).to be false
          expect(new_record.previous_token_id).to eq(old_record.id)
        end

        it "detects reuse of a rotated refresh token: 400, whole family revoked, event published" do
          initial = obtain_initial_tokens!
          old_refresh_token = initial["refresh_token"]
          old_record = record_for(old_refresh_token)

          refresh!(old_refresh_token)
          expect(response).to have_http_status(:ok)
          new_refresh_token = JSON.parse(response.body)["refresh_token"]
          new_record = record_for(new_refresh_token)
          expect(new_record.revoked?).to be false

          events = []
          subscriber = StandardId::Events.subscribe(StandardId::Events::OAUTH_REFRESH_TOKEN_REUSE_DETECTED) do |event|
            events << event
          end

          begin
            expect { refresh!(old_refresh_token) }.not_to change(StandardId::RefreshToken, :count)

            expect(response).to have_http_status(:bad_request)
            body = JSON.parse(response.body)
            expect(body["error"]).to eq("invalid_grant")
            expect(body["error_description"]).to eq("Refresh token reuse detected")

            # The entire family is revoked — including the still-live
            # descendant minted by the legitimate rotation.
            expect(old_record.reload.revoked?).to be true
            expect(new_record.reload.revoked?).to be true

            expect(events.size).to eq(1)
            expect(events.first.payload[:account_id]).to eq(account.id)
            expect(events.first.payload[:client_id]).to eq(public_client.client_id)
            expect(events.first.payload[:refresh_token_id]).to eq(old_record.id)
          ensure
            StandardId::Events.unsubscribe(subscriber)
          end
        end
      end
    end

    # describe "grant type validation" do
    #   it "recognizes client_credentials as valid grant type" do
    #     post path, params: { grant_type: "client_credentials" }, as: :json

    #     expect(response).to have_http_status(:bad_request)
    #     # Should fail on missing parameters, not unsupported grant type
    #     expect(response.body).not_to include("unsupported_grant_type")
    #   end

    #   it "recognizes authorization_code as valid grant type" do
    #     post path, params: { grant_type: "authorization_code" }, as: :json

    #     expect(response).to have_http_status(:bad_request)
    #     # Should fail on missing parameters, not unsupported grant type
    #     expect(response.body).not_to include("unsupported_grant_type")
    #   end

    #   it "recognizes password as valid grant type" do
    #     post path, params: { grant_type: "password" }, as: :json

    #     expect(response).to have_http_status(:bad_request)
    #     # Should fail on missing parameters, not unsupported grant type
    #     expect(response.body).not_to include("unsupported_grant_type")
    #   end
    # end

    # describe "response headers" do
    #   it "sets cache headers on error responses" do
    #     post path, params: { grant_type: "invalid" }, as: :json

    #     expect(response.headers["Cache-Control"]).to eq("no-cache")
    #   end

    #   it "sets cache headers on missing grant_type" do
    #     post path, params: {}, as: :json

    #     expect(response.headers["Cache-Control"]).to eq("no-cache")
    #   end
    # end

    # describe "OAuth error format" do
    #   it "returns proper OAuth error structure" do
    #     post path, params: { grant_type: "invalid" }, as: :json

    #     expect(response).to have_http_status(:bad_request)
    #     body = JSON.parse(response.body)
    #     expect(body).to have_key("error")
    #     expect(body).to have_key("error_description")
    #     expect(body["error"]).to be_a(String)
    #     expect(body["error_description"]).to be_a(String)
    #   end

    #   it "uses standard OAuth error codes" do
    #     post path, params: {}, as: :json
    #     body = JSON.parse(response.body)
    #     expect(body["error"]).to eq("invalid_request")

    #     post path, params: { grant_type: "unsupported" }, as: :json
    #     body = JSON.parse(response.body)
    #     expect(body["error"]).to eq("unsupported_grant_type")
    #   end
    # end

    # describe "controller inheritance" do
    #   it "inherits JSON content-type validation from Api::BaseController" do
    #     post path, params: {}, headers: { "CONTENT_TYPE" => "text/plain" }

    #     expect(response).to have_http_status(:bad_request)
    #     body = JSON.parse(response.body)
    #     expect(body["error"]).to eq("invalid_request")
    #     expect(body["error_description"]).to include("Content-Type")
    #   end

    #   it "inherits cache headers from Api::BaseController" do
    #     post path, params: {}, as: :json

    #     expect(response.headers["Cache-Control"]).to eq("no-cache")
    #   end
    # end
  end
end
