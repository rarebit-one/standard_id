require "rails_helper"

RSpec.describe "Rate limiting: Web Signup", type: :request do
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
  end

  def signup_params(email)
    { signup: { email: email, password: "s3cureP@ss", password_confirmation: "s3cureP@ss" } }
  end

  describe "per-IP rate limiting on POST /signup" do
    it "redirects with flash when the IP limit is exceeded" do
      ip_limit = StandardId.config.rate_limits.signup_per_ip # 10

      ip_limit.times { |i| http_post "/signup", params: signup_params("user#{i}@example.com") }

      http_post "/signup", params: signup_params("over-the-limit@example.com")
      expect(response).to redirect_to("/signup")
      expect(flash[:alert]).to eq("Too many requests. Please try again later.")
      expect(response.headers["Retry-After"]).to eq(15.minutes.to_i.to_s)
    end

    it "allows a signup within the IP limit" do
      http_post "/signup", params: signup_params("fresh@example.com")
      expect(response).not_to redirect_to("/signup")
    end
  end
end
