require "rails_helper"

RSpec.describe "Rate limiting: Web Verify Phone (RAR-56)", type: :request do
  let(:phone) { "+14155550123" }
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }

    sender = double("sms_sender")
    allow(sender).to receive(:call)
    allow(StandardId.config).to receive(:passwordless_sms_sender).and_return(sender)
  end

  describe "per-phone rate limiting on POST /verify_phone/start" do
    it "returns 429 when phone target limit is exceeded" do
      target_limit = StandardId.config.rate_limits.verification_start_per_target # 3

      target_limit.times do
        http_post "/verify_phone/start", params: { phone_number: phone }
      end

      http_post "/verify_phone/start", params: { phone_number: phone }
      expect(response).to have_http_status(:too_many_requests)
    end

    it "does not rate limit a different phone number" do
      target_limit = StandardId.config.rate_limits.verification_start_per_target # 3

      target_limit.times do
        http_post "/verify_phone/start", params: { phone_number: phone }
      end

      http_post "/verify_phone/start", params: { phone_number: "+14155550999" }
      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  describe "per-IP rate limiting on POST /verify_phone/start" do
    it "returns 429 when IP limit is exceeded" do
      ip_limit = StandardId.config.rate_limits.verification_start_per_ip # 10

      ip_limit.times do |i|
        http_post "/verify_phone/start", params: { phone_number: "+1415555012#{i}" }
      end

      http_post "/verify_phone/start", params: { phone_number: "+14155550199" }
      expect(response).to have_http_status(:too_many_requests)
    end
  end
end
