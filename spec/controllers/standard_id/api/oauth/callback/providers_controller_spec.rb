require "rails_helper"

RSpec.describe StandardId::Api::Oauth::Callback::ProvidersController, type: :controller do
  routes { StandardId::ApiEngine.routes }

  let(:apple_web_id) { "com.example.web" }
  let(:apple_mobile_id) { "com.example.mobile" }
  let(:user_info) { { email: "user@example.com" } }
  let(:account) { instance_double("Account") }
  let(:token_response) { { access_token: "token" } }
  let(:social_flow) { instance_double(StandardId::Oauth::SocialFlow, execute: token_response) }

  before do
    StandardId.config.apple_client_id = apple_web_id
    StandardId.config.apple_mobile_client_id = apple_mobile_id
    allow(StandardId::Oauth::SocialFlow).to receive(:new).and_return(social_flow)
    allow_any_instance_of(described_class).to receive(:find_or_create_account_from_social).and_return(account)
  end

  describe "POST #callback (apple)" do
    it "passes the flow parameter through" do
      expect_any_instance_of(described_class).to receive(:get_user_info_from_provider)
        .with(hash_including(flow: :mobile))
        .and_return(user_info:, tokens: {})

      post :callback, params: { provider: "apple", code: "abc123", flow: "mobile" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("access_token" => "token")
    end

    it "defaults to mobile flow when not provided" do
      expect_any_instance_of(described_class).to receive(:get_user_info_from_provider)
        .with(hash_including(flow: :mobile))
        .and_return(user_info:, tokens: {})

      post :callback, params: { provider: "apple", code: "abc123" }

      expect(response).to have_http_status(:ok)
    end

    context "with scope parameter" do
      it "passes scope parameter to SocialFlow" do
        allow_any_instance_of(described_class).to receive(:get_user_info_from_provider)
          .and_return(user_info:, tokens: {})

        expect(StandardId::Oauth::SocialFlow).to receive(:new).with(
          anything,
          anything,
          hash_including(
            account: account,
            connection: "apple",
            scopes: "profile email"
          )
        ).and_return(social_flow)

        post :callback, params: { provider: "apple", code: "abc123", scope: "profile email" }

        expect(response).to have_http_status(:ok)
      end

      it "ignores deprecated scopes parameter" do
        allow_any_instance_of(described_class).to receive(:get_user_info_from_provider)
          .and_return(user_info:, tokens: {})

        expect(StandardId::Oauth::SocialFlow).to receive(:new).with(
          anything,
          anything,
          hash_including(
            account: account,
            connection: "apple",
            scopes: nil
          )
        ).and_return(social_flow)

        post :callback, params: { provider: "apple", code: "abc123", scopes: "profile email" }

        expect(response).to have_http_status(:ok)
      end
    end

    describe "original_request_params forwarding" do
      before do
        allow_any_instance_of(described_class).to receive(:get_user_info_from_provider)
          .and_return(user_info:, tokens: {})
      end

      def capture_original_request_params(&request_block)
        captured = nil
        subscriber = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_COMPLETED) do |event|
          captured = event[:original_request_params]
        end
        request_block.call
        captured
      ensure
        StandardId::Events.unsubscribe(subscriber)
      end

      it "forwards non-reserved params to SOCIAL_AUTH_COMPLETED subscribers" do
        captured = capture_original_request_params do
          post :callback, params: {
            provider: "apple",
            code: "abc123",
            experience_slug: "spring-launch",
            utm_source: "instagram",
            utm_medium: "story",
            utm_campaign: "march-2026",
            referrer: "https://partner.example.com"
          }
        end

        expect(response).to have_http_status(:ok)
        expect(captured).to eq(
          "experience_slug" => "spring-launch",
          "utm_source" => "instagram",
          "utm_medium" => "story",
          "utm_campaign" => "march-2026",
          "referrer" => "https://partner.example.com"
        )
      end

      it "strips reserved OAuth-flow params" do
        captured = capture_original_request_params do
          post :callback, params: {
            provider: "apple",
            code: "abc123",
            id_token: "tok",
            scope: "profile",
            scopes: "profile email",
            audience: "companion_kit",
            redirect_uri: "app://callback",
            flow: "mobile",
            state: "abc",
            nonce: "xyz",
            authenticity_token: "csrf",
            utf8: "✓",
            _method: "patch",
            custom_key: "kept"
          }
        end

        expect(response).to have_http_status(:ok)
        expect(captured).to eq("custom_key" => "kept")
      end

      it "forwards an empty hash when no extra params are present" do
        captured = capture_original_request_params do
          post :callback, params: { provider: "apple", code: "abc123" }
        end

        expect(response).to have_http_status(:ok)
        expect(captured).to eq({})
      end
    end

    context "when the provider raises an OAuthError (e.g. HTTP/DNS/SSL failure)" do
      let(:oauth_error) { StandardId::OAuthError.new("Connection refused") }

      before do
        allow_any_instance_of(described_class).to receive(:get_user_info_from_provider)
          .and_raise(oauth_error)
      end

      def collect_social_auth_failed_events
        events = []
        subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_FAILED) do |event|
          events << event
        end

        yield

        events
      ensure
        StandardId::Events.unsubscribe(subscription)
      end

      it "publishes a SOCIAL_AUTH_FAILED event with the provider, error, and error_class" do
        events = collect_social_auth_failed_events do
          post :callback, params: { provider: "apple", code: "abc123" }
        end

        expect(events.size).to eq(1)
        expect(events.first[:provider]).to eq("apple")
        expect(events.first[:error]).to eq("Connection refused")
        expect(events.first[:error_class]).to eq("StandardId::OAuthError")
      end

      it "still renders the standard OAuth error JSON response" do
        post :callback, params: { provider: "apple", code: "abc123" }

        expect(response).to have_http_status(oauth_error.http_status)
        expect(response.parsed_body["error"]).to eq(oauth_error.oauth_error_code.to_s)
        expect(response.parsed_body["error_description"]).to eq("Connection refused")
      end

      it "does NOT publish for OAuthError subclasses raised after the provider call" do
        allow_any_instance_of(described_class).to receive(:get_user_info_from_provider)
          .and_return(user_info:, tokens: {})
        allow_any_instance_of(described_class).to receive(:find_or_create_account_from_social)
          .and_raise(StandardId::SocialLinkError.new(email: "user@example.com", provider_name: "apple"))

        events = collect_social_auth_failed_events do
          post :callback, params: { provider: "apple", code: "abc123" }
        end

        expect(events).to be_empty
      end
    end
  end
end
