require "rails_helper"

# Api::Oauth::BaseController renders OAuth errors with its own handler (an
# RFC 6749 §5.2 error object). An error that knows how long to wait (one
# responding to a positive `retry_after`, as StandardId::RateLimitExceededError
# does) gets the same Retry-After header the resource endpoints' handler sends;
# the body and status are whatever the handler renders without it.
RSpec.describe "Retry-After on OAuth error responses", type: :request do
  let(:waiting_error_class) do
    Class.new(StandardId::InvalidGrantError) do
      attr_reader :retry_after

      def initialize(message = "slow down", retry_after: nil)
        super(message)
        @retry_after = retry_after
      end
    end
  end

  def json = JSON.parse(response.body)

  describe "POST /api/oauth/callback/:provider" do
    before do
      allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
      allow(StandardId::Providers::Google).to receive(:get_user_info).and_return(
        { user_info: { "email" => "retry-after-#{SecureRandom.hex(4)}@example.com", "email_verified" => true,
                       "sub" => "g-#{SecureRandom.hex(4)}" }, tokens: { "id_token" => "t" } }.with_indifferent_access
      )
    end

    def callback_raising(error)
      allow(StandardId.config.social).to receive(:before_mint).and_return(->(account:) { raise error })
      post "/api/oauth/callback/google", params: { code: "c" }
    end

    it "sends Retry-After for an OAuthError subclass with retry_after: 30, body and status unchanged" do
      callback_raising(waiting_error_class.new(retry_after: 30))

      expect(response.headers["Retry-After"]).to eq("30")
      expect(response).to have_http_status(:bad_request)
      expect(json).to eq("error" => "invalid_grant", "error_description" => "slow down")
    end

    it "sends no Retry-After when the same error has no retry_after, body and status unchanged" do
      callback_raising(waiting_error_class.new)

      expect(response.headers["Retry-After"]).to be_nil
      expect(response).to have_http_status(:bad_request)
      expect(json).to eq("error" => "invalid_grant", "error_description" => "slow down")
    end

    it "sends no Retry-After for a zero retry_after" do
      callback_raising(waiting_error_class.new(retry_after: 0))

      expect(response.headers["Retry-After"]).to be_nil
      expect(response).to have_http_status(:bad_request)
    end

    it "sends no Retry-After for an OAuthError that has no retry_after at all" do
      callback_raising(StandardId::InvalidGrantError.new("region blocked"))

      expect(response.headers["Retry-After"]).to be_nil
      expect(response).to have_http_status(:bad_request)
      expect(json).to eq("error" => "invalid_grant", "error_description" => "region blocked")
    end

    it "sends Retry-After for a lib-level rate limit (RateLimitExceededError) as a 429" do
      callback_raising(StandardId::RateLimitExceededError.new(retry_after: 900))

      expect(response.headers["Retry-After"]).to eq("900")
      expect(response).to have_http_status(:too_many_requests)
      expect(json).to eq("error" => "rate_limit_exceeded", "error_description" => "Too many requests. Please try again later.")
    end
  end

  describe "POST /api/oauth/callback/:provider when the network_wrapper refuses the request" do
    let(:refusal_class) do
      Class.new(StandardError) do
        attr_reader :retry_after

        def initialize(retry_after: nil)
          super("oauth_google is open")
          @retry_after = retry_after
        end
      end
    end

    before do
      allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
      allow(Resolv).to receive(:getaddresses).and_return(["93.184.216.34"])
      # A plugin's code exchange: one HttpClient call naming the provider, so
      # it goes through the wrapper.
      allow(StandardId::Providers::Google).to receive(:get_user_info) do
        StandardId::HttpClient.post_form("https://oauth2.example.com/token", { code: "c" }, provider: :google)
        raise "the wrapper refuses the request, so this is never reached"
      end
    end

    def callback_refused_with(error)
      StandardId.config.network_wrapper = ->(provider:, &_block) { raise error }
      post "/api/oauth/callback/google", params: { code: "c" }
    end

    it "answers 503 temporarily_unavailable with Retry-After when the refusal carries retry_after" do
      callback_refused_with(refusal_class.new(retry_after: 30))

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("30")
      expect(json).to eq("error" => "temporarily_unavailable", "error_description" => "Google is temporarily unavailable")
    end

    it "answers 503 without Retry-After when the refusal says nothing about waiting" do
      callback_refused_with(refusal_class.new)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to be_nil
      expect(json).to eq("error" => "temporarily_unavailable", "error_description" => "Google is temporarily unavailable")
    end
  end

  describe "POST /api/oauth/token" do
    def token_request_raising(error)
      allow(StandardId::Oauth::GrantTypes).to receive(:disabled?).and_raise(error)
      post "/api/oauth/token", params: { grant_type: "client_credentials" }
    end

    it "sends Retry-After for an OAuthError subclass with retry_after: 30, body and status unchanged" do
      token_request_raising(waiting_error_class.new(retry_after: 30))

      expect(response.headers["Retry-After"]).to eq("30")
      expect(response).to have_http_status(:bad_request)
      expect(json).to eq("error" => "invalid_grant", "error_description" => "slow down")
    end

    it "sends no Retry-After when the error has no retry_after, body and status unchanged" do
      token_request_raising(waiting_error_class.new)

      expect(response.headers["Retry-After"]).to be_nil
      expect(response).to have_http_status(:bad_request)
      expect(json).to eq("error" => "invalid_grant", "error_description" => "slow down")
    end
  end
end
