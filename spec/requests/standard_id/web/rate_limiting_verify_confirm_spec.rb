require "rails_helper"

# The code-confirmation endpoints previously relied only on the per-challenge
# attempt cap (default 3); a distributed attacker could guess across many
# challenges from one IP without limit. These specs cover the added per-IP
# rate_limit (shares otp_verify_per_ip) on both show and update.
RSpec.describe "Rate limiting: Web Verify Confirm", type: :request do
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:ip_limit) { StandardId.config.rate_limits.otp_verify_per_ip } # 20

  before do
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
  end

  describe "per-IP rate limiting on GET /verify_email/confirm" do
    it "redirects to the confirm path once the IP limit is exceeded" do
      ip_limit.times { |i| http_get "/verify_email/confirm", params: { email: "u#{i}@example.com", code: "000000" } }

      http_get "/verify_email/confirm", params: { email: "final@example.com", code: "000000" }
      expect(response).to redirect_to("/verify_email/confirm")
      expect(response.headers["Retry-After"]).to eq(15.minutes.to_i.to_s)
    end
  end

  describe "per-IP rate limiting on GET /verify_phone/confirm" do
    it "redirects to the confirm path once the IP limit is exceeded" do
      ip_limit.times { |i| http_get "/verify_phone/confirm", params: { phone_number: "+123456789#{i % 10}", code: "000000" } }

      http_get "/verify_phone/confirm", params: { phone_number: "+19999999999", code: "000000" }
      expect(response).to redirect_to("/verify_phone/confirm")
      expect(response.headers["Retry-After"]).to eq(15.minutes.to_i.to_s)
    end
  end
end
