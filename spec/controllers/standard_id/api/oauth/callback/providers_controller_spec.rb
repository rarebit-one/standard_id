require "rails_helper"

RSpec.describe StandardId::Api::Oauth::Callback::ProvidersController, type: :controller do
  routes { StandardId::ApiEngine.routes }

  let(:apple_web_id) { "com.example.web" }
  let(:apple_mobile_id) { "com.example.mobile" }
  let(:user_info) { { email: "user@example.com" } }
  let(:account) { instance_double("Account") }
  let(:token_response) { { access_token: "token" } }

  before do
    StandardId.config.apple_client_id = apple_web_id
    StandardId.config.apple_mobile_client_id = apple_mobile_id
    allow(StandardId::Oauth::SocialFlow).to receive(:new).and_return(instance_double(StandardId::Oauth::SocialFlow, execute: token_response))
    allow_any_instance_of(described_class).to receive(:find_or_create_account_from_social).and_return(account)
  end

  describe "POST #apple" do
    it "passes the flow parameter through" do
      expect_any_instance_of(described_class).to receive(:get_user_info_from_provider)
        .with("apple", hash_including(flow: :mobile))
        .and_return(user_info)

      post :apple, params: { code: "abc123", flow: "mobile" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("access_token" => "token")
    end

    it "defaults to web flow when not provided" do
      expect_any_instance_of(described_class).to receive(:get_user_info_from_provider)
        .with("apple", hash_including(flow: :web))
        .and_return(user_info)

      post :apple, params: { code: "abc123" }

      expect(response).to have_http_status(:ok)
    end
  end
end
