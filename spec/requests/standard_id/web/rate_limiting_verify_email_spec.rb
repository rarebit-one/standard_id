require "rails_helper"

RSpec.describe "Rate limiting: Web Verify Email (RAR-56)", type: :request do
  let(:email) { "user@example.com" }
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }

    sender = double("email_sender")
    allow(sender).to receive(:call)
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)
  end

  describe "per-email rate limiting on POST /verify_email/start" do
    it "returns 429 when email target limit is exceeded" do
      target_limit = StandardId.config.rate_limits.verification_start_per_target # 3

      target_limit.times do
        http_post "/verify_email/start", params: { email: email }
      end

      http_post "/verify_email/start", params: { email: email }
      expect(response).to have_http_status(:too_many_requests)
    end

    it "does not rate limit a different email" do
      target_limit = StandardId.config.rate_limits.verification_start_per_target # 3

      target_limit.times do
        http_post "/verify_email/start", params: { email: email }
      end

      http_post "/verify_email/start", params: { email: "other@example.com" }
      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  describe "per-IP rate limiting on POST /verify_email/start" do
    it "returns 429 when IP limit is exceeded" do
      ip_limit = StandardId.config.rate_limits.verification_start_per_ip # 10

      ip_limit.times do |i|
        http_post "/verify_email/start", params: { email: "user#{i}@example.com" }
      end

      http_post "/verify_email/start", params: { email: "another@example.com" }
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "response format" do
    it "returns flash alert for web requests" do
      target_limit = StandardId.config.rate_limits.verification_start_per_target # 3

      target_limit.times do
        http_post "/verify_email/start", params: { email: email }
      end

      http_post "/verify_email/start", params: { email: email }
      expect(response).to have_http_status(:too_many_requests)
      expect(flash[:alert]).to eq("Too many requests. Please try again later.")
    end
  end
end
