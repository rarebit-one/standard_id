require "rails_helper"

RSpec.describe "Rate limiting: API OAuth Tokens per audience", type: :request do
  let(:path) { "/api/oauth/token" }
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
  end

  def request_token(audience: nil)
    params = { grant_type: "client_credentials", client_id: "test", client_secret: "secret" }
    params[:audience] = audience if audience
    http_post_json path, params: params
  end

  context "when api_token_per_audience_per_ip is not configured (default)" do
    it "applies no per-audience limit" do
      5.times do
        request_token(audience: "mobile_app")
        expect(response).not_to have_http_status(:too_many_requests)
      end
    end
  end

  context "when api_token_per_audience_per_ip is configured" do
    before do
      allow(StandardId.config.rate_limits)
        .to receive(:api_token_per_audience_per_ip)
        .and_return({ "mobile_app" => 3 })
    end

    it "returns 429 once the audience cap is exceeded" do
      3.times do
        request_token(audience: "mobile_app")
        expect(response).not_to have_http_status(:too_many_requests)
      end

      request_token(audience: "mobile_app")
      expect(response).to have_http_status(:too_many_requests)
    end

    it "renders the standard JSON rate-limit error with Retry-After" do
      4.times { request_token(audience: "mobile_app") }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to be_present
      body = json_body
      expect(body["error"]).to eq("rate_limit_exceeded")
      expect(body["error_description"]).to include("Too many requests")
    end

    it "does not count requests for other audiences toward the cap" do
      10.times do
        request_token(audience: "partner_api")
        expect(response).not_to have_http_status(:too_many_requests)
      end

      request_token(audience: "mobile_app")
      expect(response).not_to have_http_status(:too_many_requests)
    end

    it "does not count requests with no audience toward the cap" do
      10.times do
        request_token
        expect(response).not_to have_http_status(:too_many_requests)
      end

      request_token(audience: "mobile_app")
      expect(response).not_to have_http_status(:too_many_requests)
    end

    it "tracks each audience under a separate per-IP counter" do
      allow(StandardId.config.rate_limits)
        .to receive(:api_token_per_audience_per_ip)
        .and_return({ "mobile_app" => 3, "partner_api" => 3 })

      3.times { request_token(audience: "mobile_app") }
      request_token(audience: "mobile_app")
      expect(response).to have_http_status(:too_many_requests)

      request_token(audience: "partner_api")
      expect(response).not_to have_http_status(:too_many_requests)
    end

    it "supports symbol keys in the configured hash" do
      allow(StandardId.config.rate_limits)
        .to receive(:api_token_per_audience_per_ip)
        .and_return({ mobile_app: 2 })

      2.times { request_token(audience: "mobile_app") }
      request_token(audience: "mobile_app")
      expect(response).to have_http_status(:too_many_requests)
    end

    it "ignores non-string audience param shapes" do
      request_token(audience: { "mobile_app" => "1" })
      expect(response).not_to have_http_status(:too_many_requests)
    end
  end
end
