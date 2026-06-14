require "rails_helper"

RSpec.describe "Rate limiting: Web Login Verify (RAR-60)", type: :request do
  let(:email) { "user@example.com" }
  let(:connection) { "email" }
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(StandardId::RateLimitHandling::RATE_LIMIT_STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }

    allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
    allow(StandardId.config.passwordless).to receive(:connection).and_return(connection)
  end

  def initiate_passwordless_login!
    sender = double("email_sender")
    allow(sender).to receive(:call)
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(sender)

    http_post "/login", params: { login: { email: email } }
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to("/login_verify")
  end

  describe "per-IP rate limiting on PATCH /login_verify" do
    let!(:account) do
      account = Account.create!(name: "Test User", email: email)
      StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
      account
    end

    it "returns 429 when IP rate limit is exceeded" do
      initiate_passwordless_login!

      ip_limit = StandardId.config.rate_limits.otp_verify_per_ip # 20

      ip_limit.times do
        http_patch "/login_verify", params: { code: "000000" }
      end

      http_patch "/login_verify", params: { code: "000000" }
      expect(response).to redirect_to("/login_verify")
      expect(flash[:alert]).to eq("Too many requests. Please try again later.")
    end

    it "allows requests within the limit" do
      initiate_passwordless_login!

      2.times do
        http_patch "/login_verify", params: { code: "000000" }
        expect(response).not_to redirect_to("/login_verify")
      end
    end
  end
end
