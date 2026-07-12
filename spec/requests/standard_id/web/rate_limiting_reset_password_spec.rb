require "rails_helper"

RSpec.describe "Rate limiting: Web Reset Password Start", type: :request do
  let(:email) { "user@example.com" }
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    # Use a real cache store so the native rate_limit actually fires (the test
    # env cache is the null store, which never trips).
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
  end

  describe "per-email rate limiting on POST /reset_password/start" do
    it "redirects with flash when the email target limit is exceeded" do
      target_limit = StandardId.config.rate_limits.password_reset_start_per_target # 3

      target_limit.times { http_post "/reset_password/start", params: { email: email } }

      http_post "/reset_password/start", params: { email: email }
      expect(response).to redirect_to("/reset_password/start")
      expect(flash[:alert]).to eq("Too many requests. Please try again later.")
    end

    it "does not rate limit a different email" do
      target_limit = StandardId.config.rate_limits.password_reset_start_per_target # 3

      target_limit.times { http_post "/reset_password/start", params: { email: email } }

      http_post "/reset_password/start", params: { email: "other@example.com" }
      expect(response).not_to redirect_to("/reset_password/start")
    end
  end

  describe "per-IP rate limiting on POST /reset_password/start" do
    it "redirects when the IP limit is exceeded across many emails" do
      ip_limit = StandardId.config.rate_limits.password_reset_start_per_ip # 10

      ip_limit.times { |i| http_post "/reset_password/start", params: { email: "user#{i}@example.com" } }

      http_post "/reset_password/start", params: { email: "another@example.com" }
      expect(response).to redirect_to("/reset_password/start")
      expect(response.headers["Retry-After"]).to eq(15.minutes.to_i.to_s)
    end
  end
end
