require "rails_helper"

RSpec.describe "StandardId Web Social Auth Callbacks", type: :request do
  describe "GET /auth/callback/google" do
    let(:state) { SecureRandom.urlsafe_base64(32) }
    let(:redirect_uri) { "/dashboard" }

    before do
      allow(StandardId.config).to receive(:account_class_name).and_return("Account")
      allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
      allow(StandardId.config).to receive(:google_client_secret).and_return("google-secret")
      allow(StandardId::Providers::Google).to receive(:get_user_info).and_return(
        {
          user_info: { "email" => "user@example.com", "name" => "Test User", "sub" => "prov_123" },
          tokens: { access_token: "token_123" }
        }.with_indifferent_access
      )

      # Stub the controller's consume_oauth_request method to return our test params
      # This bypasses the cookie encryption complexity in request specs
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
        .to receive(:consume_oauth_request)
        .with(state)
        .and_return({ "params" => { "redirect_uri" => redirect_uri }, "nonce" => nil })
    end

    it "signs in and redirects to redirect_uri from social_login_params" do
      http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

      expect(StandardId::Providers::Google).to have_received(:get_user_info).with(
        hash_including(code: "auth_code_123", redirect_uri: "http://www.example.com/auth/callback/google")
      )
      expect(response).to redirect_to("/dashboard")
      follow_redirect! if response.redirect?
      account = Account.find_by(email: "user@example.com")
      expect(account).to be_present
      expect(account.sessions.active).to exist
    end

    it "redirects to login when state missing" do
      http_get "/auth/callback/google", params: { code: "auth_code_123" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Missing state parameter")
    end

    it "redirects to login when state mismatch (CSRF protection)" do
      different_state = SecureRandom.urlsafe_base64(32)
      # The stub is for 'state', but we're sending 'different_state', so consume_oauth_request won't match
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController).to receive(:consume_oauth_request).with(different_state).and_return(nil)
      http_get "/auth/callback/google", params: { state: different_state, code: "auth_code_123" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Invalid or expired state parameter")
    end

    it "redirects to login with error when provider passes error param (access_denied)" do
      http_get "/auth/callback/google", params: { error: "access_denied" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Authentication was cancelled")
    end

    it "redirects to login with error when provider passes error param (invalid_request)" do
      http_get "/auth/callback/google", params: { error: "invalid_request" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Invalid authentication request")
    end

    it "redirects to login with generic error when provider passes unknown error" do
      http_get "/auth/callback/google", params: { error: "some_error" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Authentication failed")
    end

    it "preserves redirect_uri across handle_callback_error (provider cancel path)" do
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
        .to receive(:consume_oauth_request)
        .with(state)
        .and_return({ "params" => { "redirect_uri" => "/oauth/authorize?client_id=harness" }, "nonce" => nil })

      http_get "/auth/callback/google", params: { error: "access_denied", state: state }

      expect(response).to redirect_to(standard_id_web.login_path(redirect_uri: "/oauth/authorize?client_id=harness"))
    end

    describe "safe_destination? validation" do
      it "falls back to / when hook defers and state_data redirect_uri is a cross-host URL not in the allow list" do
        hook = ->(_account, _request, _context) { nil }
        allow(StandardId.config).to receive(:after_sign_in).and_return(hook)
        allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
          .to receive(:consume_oauth_request)
          .with(state)
          .and_return({ "params" => { "redirect_uri" => "https://evil.example.com/phish" }, "nonce" => nil })

        http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

        expect(response).to redirect_to("/")
      end

      it "falls back to / when state_data redirect_uri is a protocol-relative URL" do
        hook = ->(_account, _request, _context) { nil }
        allow(StandardId.config).to receive(:after_sign_in).and_return(hook)
        allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
          .to receive(:consume_oauth_request)
          .with(state)
          .and_return({ "params" => { "redirect_uri" => "//evil.example.com/phish" }, "nonce" => nil })

        http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

        expect(response).to redirect_to("/")
      end

      it "allows same-origin paths after defer" do
        hook = ->(_account, _request, _context) { nil }
        allow(StandardId.config).to receive(:after_sign_in).and_return(hook)
        # Default stub above sets redirect_uri = "/dashboard"

        http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

        expect(response).to redirect_to("/dashboard")
      end

      it "allows cross-host URLs matching allowed_redirect_url_prefixes after defer" do
        original = StandardId.config.allowed_redirect_url_prefixes
        StandardId.config.allowed_redirect_url_prefixes = ["sidekicklabs://"]
        hook = ->(_account, _request, _context) { nil }
        allow(StandardId.config).to receive(:after_sign_in).and_return(hook)
        allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
          .to receive(:consume_oauth_request)
          .with(state)
          .and_return({ "params" => { "redirect_uri" => "sidekicklabs://callback" }, "nonce" => nil })

        http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

        expect(response).to redirect_to("sidekicklabs://callback")
      ensure
        StandardId.config.allowed_redirect_url_prefixes = original
      end
    end

    context "when the provider raises an OAuthError (e.g. HTTP/DNS/SSL failure)" do
      let(:oauth_error) { StandardId::OAuthError.new("Connection refused") }

      before do
        allow(StandardId::Providers::Google).to receive(:get_user_info).and_raise(oauth_error)
      end

      it "publishes a SOCIAL_AUTH_FAILED event with the provider, error, and error_class" do
        events = []
        subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_FAILED) do |event|
          events << event
        end

        begin
          http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

          expect(events.size).to eq(1)
          expect(events.first[:provider]).to eq("google")
          expect(events.first[:error]).to eq("Connection refused")
          expect(events.first[:error_class]).to eq("StandardId::OAuthError")
        ensure
          StandardId::Events.unsubscribe(subscription)
        end
      end

      it "still redirects to the login path with a user-facing alert" do
        http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

        expect(response).to redirect_to(standard_id_web.login_path(redirect_uri: redirect_uri))
        expect(flash[:alert]).to include("Authentication failed: Connection refused")
      end
    end

    context "when a SocialLinkError is raised (policy error, not infrastructure)" do
      let(:link_error) do
        StandardId::SocialLinkError.new(email: "user@example.com", provider_name: "google")
      end

      before do
        allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
          .to receive(:find_or_create_account_from_social)
          .and_raise(link_error)
      end

      it "does NOT publish SOCIAL_AUTH_FAILED (which is reserved for infrastructure failures)" do
        events = []
        subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_FAILED) do |event|
          events << event
        end

        begin
          http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

          expect(events).to be_empty
        ensure
          StandardId::Events.unsubscribe(subscription)
        end
      end

      it "still redirects to the login path with the link error message" do
        http_get "/auth/callback/google", params: { state: state, code: "auth_code_123" }

        expect(response).to redirect_to(standard_id_web.login_path(redirect_uri: redirect_uri))
        expect(flash[:alert]).to include("Authentication failed:")
        expect(flash[:alert]).to include("already associated")
      end
    end
  end

  describe "POST /auth/callback/apple" do
    let(:apple_state) { SecureRandom.urlsafe_base64(32) }
    let(:apple_redirect_uri) { "/dashboard" }

    before do
      allow(StandardId.config).to receive(:apple_client_id).and_return("com.example.app")
      allow(StandardId::Providers::Apple).to receive(:get_user_info).and_return(
        {
          user_info: { "email" => "user@privaterelay.appleid.com", "name" => "Apple User", "sub" => "apple_123" },
          tokens: { id_token: "apple_token_123" }
        }.with_indifferent_access
      )

      # Stub the controller's consume_oauth_request method
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
        .to receive(:consume_oauth_request)
        .with(apple_state)
        .and_return({ "params" => { "redirect_uri" => apple_redirect_uri }, "nonce" => nil })
    end

    it "signs in and redirects to redirect_uri from social_login_params" do
      http_post "/auth/callback/apple", params: { state: apple_state, code: "apple_code_123" }

      expect(StandardId::Providers::Apple).to have_received(:get_user_info).with(
        hash_including(code: "apple_code_123", redirect_uri: "http://www.example.com/auth/callback/apple")
      )
      expect(response).to redirect_to("/dashboard")
    end

    it "redirects to login when state missing" do
      http_post "/auth/callback/apple", params: { email: "user@privaterelay.appleid.com" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Missing state parameter")
    end

    it "redirects to login when state mismatch" do
      different_state = SecureRandom.urlsafe_base64(32)
      allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController).to receive(:consume_oauth_request).with(different_state).and_return(nil)
      http_post "/auth/callback/apple", params: { state: different_state, email: "user@privaterelay.appleid.com" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to include("Invalid or expired state parameter")
    end

    it "redirects to login with error when provider passes error param (access_denied)" do
      http_post "/auth/callback/apple", params: { error: "access_denied" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Authentication was cancelled")
    end

    it "redirects to login with error when provider passes error param (invalid_request)" do
      http_post "/auth/callback/apple", params: { error: "invalid_request" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Invalid authentication request")
    end

    it "redirects to login with generic error when provider passes unknown error" do
      http_post "/auth/callback/apple", params: { error: "some_error" }
      expect(response).to redirect_to(standard_id_web.login_path)
      expect(flash[:alert]).to eq("Authentication failed")
    end
  end
end
