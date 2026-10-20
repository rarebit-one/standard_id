require "rails_helper"

# How a lib-level OTP start limit (rate_limits.otp_start_per_target, enforced
# inside the strategy) surfaces on each engine surface. Only the lib limit is
# stubbed, to 1, below every controller-level default (5+), so it is the one
# that trips. The controller limits are deliberately NOT stubbed: `rate_limit`
# reads them when the controller class loads, so a stub active at that moment
# would be baked into the class for the rest of the process.
RSpec.describe "Rendering a lib-level OTP start limit", type: :request do
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(StandardId::RateLimiter::STORE)
      .to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
    allow(StandardId::Passwordless).to receive(:retry_delay).and_return(0)
    allow(StandardId.config.rate_limits).to receive(:otp_start_per_target).and_return(1)
  end

  it "answers 429 rate_limit_exceeded with Retry-After on the API" do
    http_post_json "/api/passwordless/start", params: { connection: "email", email: "user@example.com" }
    expect(response).to have_http_status(:ok)

    http_post_json "/api/passwordless/start", params: { connection: "email", email: "user@example.com" }

    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"]).to eq("900")
    expect(json_body).to eq("error" => "rate_limit_exceeded", "error_description" => "Too many requests. Please try again later.")
  end

  it "shows the message as a flash on the web login page" do
    allow(StandardId.config.web).to receive(:passwordless_login).and_return(true)
    http_post "/login", params: { login: { email: "user@example.com" } }
    expect(response).not_to have_http_status(:unprocessable_content)

    http_post "/login", params: { login: { email: "user@example.com" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(flash[:alert]).to eq("Too many requests. Please try again later.")
  end
end
