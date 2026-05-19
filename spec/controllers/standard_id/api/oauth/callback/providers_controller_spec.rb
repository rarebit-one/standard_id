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
  end
end
