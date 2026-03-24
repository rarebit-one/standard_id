require "rails_helper"

RSpec.describe "Rate limiting: API OAuth Tokens (RAR-51/RAR-60)", type: :request do
  let(:path) { "/api/oauth/token" }
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
  end

  describe "per-IP rate limiting on POST /api/oauth/token" do
    it "returns 429 when IP limit is exceeded" do
      ip_limit = StandardId.config.rate_limits.api_token_per_ip # 30

      ip_limit.times do
        http_post_json path, params: { grant_type: "client_credentials", client_id: "test", client_secret: "secret" }
      end

      http_post_json path, params: { grant_type: "client_credentials", client_id: "test", client_secret: "secret" }
      expect(response).to have_http_status(:too_many_requests)
    end

    it "returns JSON error body for rate limited requests" do
      ip_limit = StandardId.config.rate_limits.api_token_per_ip # 30

      ip_limit.times do
        http_post_json path, params: { grant_type: "client_credentials", client_id: "test", client_secret: "secret" }
      end

      http_post_json path, params: { grant_type: "client_credentials", client_id: "test", client_secret: "secret" }
      expect(response).to have_http_status(:too_many_requests)
      body = json_body
      expect(body["error"]).to eq("rate_limit_exceeded")
      expect(body["error_description"]).to include("Too many requests")
    end

    it "allows requests within the limit" do
      3.times do
        http_post_json path, params: { grant_type: "client_credentials", client_id: "test", client_secret: "secret" }
        # The request may fail with 400 (invalid client) but should NOT be 429
        expect(response).not_to have_http_status(:too_many_requests)
      end
    end
  end
end
