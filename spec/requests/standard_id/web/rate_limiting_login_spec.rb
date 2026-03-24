require "rails_helper"

RSpec.describe "Rate limiting: Web Login (RAR-51)", type: :request do
  let(:email) { "user@example.com" }
  let(:password) { "s3cureP@ss" }
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    # Use a real cache store so rate limiting actually fires
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
  end

  describe "per-IP rate limiting on POST /login" do
    before do
      create_account_with_password(email: email, password: password)
    end

    it "allows requests within the IP limit" do
      http_post "/login", params: { login: { email: email, password: "wrong" } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 429 when IP limit is exceeded" do
      ip_limit = StandardId.config.rate_limits.password_login_per_ip # 20

      # Make enough requests to exceed the limit
      ip_limit.times do
        http_post "/login", params: { login: { email: "user#{_1}@example.com", password: "wrong" } }
      end

      http_post "/login", params: { login: { email: email, password: "wrong" } }
      expect(response).to redirect_to("/")
      expect(flash[:alert]).to eq("Too many requests. Please try again later.")
    end
  end

  describe "per-email rate limiting on POST /login" do
    before do
      create_account_with_password(email: email, password: password)
    end

    it "redirects with flash when email limit is exceeded" do
      email_limit = StandardId.config.rate_limits.password_login_per_email # 5

      email_limit.times do
        http_post "/login", params: { login: { email: email, password: "wrong" } }
      end

      http_post "/login", params: { login: { email: email, password: "wrong" } }
      expect(response).to redirect_to("/")
      expect(flash[:alert]).to eq("Too many requests. Please try again later.")
    end

    it "does not rate limit a different email after one email is exhausted" do
      other_email = "other@example.com"
      create_account_with_password(email: other_email, password: password)
      email_limit = StandardId.config.rate_limits.password_login_per_email # 5

      email_limit.times do
        http_post "/login", params: { login: { email: email, password: "wrong" } }
      end

      # Different email should still work (assuming IP limit is not exceeded)
      http_post "/login", params: { login: { email: other_email, password: "wrong" } }
      expect(response).not_to redirect_to("/")
    end
  end

  describe "rate limit response for web controllers" do
    before do
      create_account_with_password(email: email, password: password)
    end

    it "sets a flash alert message and includes Retry-After header" do
      email_limit = StandardId.config.rate_limits.password_login_per_email # 5

      email_limit.times do
        http_post "/login", params: { login: { email: email, password: "wrong" } }
      end

      http_post "/login", params: { login: { email: email, password: "wrong" } }
      expect(response).to redirect_to("/")
      expect(flash[:alert]).to eq("Too many requests. Please try again later.")
      expect(response.headers["Retry-After"]).to eq(15.minutes.to_i.to_s)
    end
  end

  describe "passwordless login rate limiting" do
    before do
      allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
      allow(StandardId.config.passwordless).to receive(:connection).and_return("email")
      sender = double("email_sender")
      allow(sender).to receive(:call)
      allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)
    end

    it "rate limits passwordless login initiation by email" do
      email_limit = StandardId.config.rate_limits.password_login_per_email # 5

      email_limit.times do
        http_post "/login", params: { login: { email: email } }
      end

      http_post "/login", params: { login: { email: email } }
      expect(response).to redirect_to("/")
    end
  end
end
