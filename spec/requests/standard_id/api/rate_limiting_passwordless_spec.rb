require "rails_helper"

RSpec.describe "Rate limiting: API Passwordless (RAR-60)", type: :request do
  let(:path) { "/api/passwordless/start" }
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }

    sender = double("email_sender")
    allow(sender).to receive(:call)
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)
  end

  describe "per-IP rate limiting on POST /api/passwordless/start" do
    it "returns 429 when IP limit is exceeded" do
      ip_limit = StandardId.config.rate_limits.api_passwordless_start_per_ip # 10

      ip_limit.times do |i|
        http_post_json path, params: { connection: "email", email: "user#{i}@example.com" }
      end

      http_post_json path, params: { connection: "email", email: "new@example.com" }
      expect(response).to have_http_status(:too_many_requests)
      body = json_body
      expect(body["error"]).to eq("rate_limit_exceeded")
      expect(body["error_description"]).to include("Too many requests")
    end
  end

  describe "per-target rate limiting on POST /api/passwordless/start" do
    it "returns 429 when target limit is exceeded for same email" do
      target_limit = StandardId.config.rate_limits.api_passwordless_start_per_target # 5

      target_limit.times do
        http_post_json path, params: { connection: "email", email: "user@example.com" }
      end

      http_post_json path, params: { connection: "email", email: "user@example.com" }
      expect(response).to have_http_status(:too_many_requests)
    end

    it "does not rate limit a different email when target limit is hit but IP limit is not" do
      target_limit = StandardId.config.rate_limits.api_passwordless_start_per_target # 5

      target_limit.times do
        http_post_json path, params: { connection: "email", email: "user@example.com" }
      end

      # Different email should still work (IP limit is 10, we've only made 5 requests)
      http_post_json path, params: { connection: "email", email: "other@example.com" }
      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  describe "JSON response format" do
    it "returns a JSON error body when rate limited" do
      ip_limit = StandardId.config.rate_limits.api_passwordless_start_per_ip # 10

      ip_limit.times do |i|
        http_post_json path, params: { connection: "email", email: "user#{i}@example.com" }
      end

      http_post_json path, params: { connection: "email", email: "final@example.com" }
      expect(response).to have_http_status(:too_many_requests)
      body = json_body
      expect(body["error"]).to eq("rate_limit_exceeded")
      expect(body["error_description"]).to eq("Too many requests. Please try again later.")
    end
  end
end
