require "rails_helper"

# Regression: the password grant 500'd for every existing user (bad preload of
# `credential: :account`) and on a wrong password (`false.account`).
RSpec.describe "POST /api/oauth/token grant_type=password", type: :request do
  let(:path) { "/api/oauth/token" }
  let(:email) { "grant-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "s3cureP@ss" }

  before { create_account_with_password(email: email, password: password) }

  def grant(pw)
    post path, params: { grant_type: "password", username: email, password: pw, client_id: "test-client" }, as: :json
    JSON.parse(response.body)
  end

  it "issues tokens for an existing user with the right password" do
    body = grant(password)

    expect(response).to have_http_status(:ok)
    expect(body["access_token"]).to be_present
    expect(body["refresh_token"]).to be_present
    expect(StandardId::JwtService.decode(body["access_token"])[:sub].to_s).to eq(Account.find_by(email: email).id.to_s)
  end

  it "answers 400 invalid_grant for a wrong password" do
    body = grant("wrong-password")

    expect(response).to have_http_status(:bad_request)
    expect(body).to eq("error" => "invalid_grant", "error_description" => "Invalid username or password")
  end

  it "answers the same 400 invalid_grant for an unknown login" do
    post path, params: { grant_type: "password", username: "nobody@example.com", password: password, client_id: "test-client" }, as: :json

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body)["error"]).to eq("invalid_grant")
  end

  context "when the grant is disabled via oauth.disabled_grant_types" do
    before { allow(StandardId.config.oauth).to receive(:disabled_grant_types).and_return(%w[password]) }

    it "answers 400 unsupported_grant_type exactly like an unknown grant, for a known login" do
      body = grant(password)

      expect(response).to have_http_status(:bad_request)
      expect(body).to eq("error" => "unsupported_grant_type", "error_description" => "Unsupported grant_type: password")
    end

    it "answers the same for an unknown login and for a request missing the flow's params" do
      post path, params: { grant_type: "password", username: "nobody@example.com", password: password, client_id: "test-client" }, as: :json
      unknown = JSON.parse(response.body)

      post path, params: { grant_type: "password" }, as: :json
      bare = JSON.parse(response.body)

      expect(unknown).to eq("error" => "unsupported_grant_type", "error_description" => "Unsupported grant_type: password")
      expect(bare).to eq(unknown)
    end

    it "accepts symbols in the list" do
      allow(StandardId.config.oauth).to receive(:disabled_grant_types).and_return([:password])

      grant(password)

      expect(JSON.parse(response.body)["error"]).to eq("unsupported_grant_type")
    end

    it "leaves other grants alone" do
      post path, params: { grant_type: "refresh_token", refresh_token: "nope", client_id: "test-client" }, as: :json

      expect(JSON.parse(response.body)["error"]).not_to eq("unsupported_grant_type")
    end
  end

  context "when oauth.password_grant_requires_verified_identifier is on" do
    before { allow(StandardId.config.oauth).to receive(:password_grant_requires_verified_identifier).and_return(true) }

    it "still issues tokens for a verified identifier" do
      body = grant(password)

      expect(response).to have_http_status(:ok)
      expect(body["access_token"]).to be_present
    end

    it "refuses an unverified identifier with the wrong-password answer and an identifier_unverified failure event" do
      StandardId::EmailIdentifier.find_by!(value: email).update!(verified_at: nil)
      failures = []
      StandardId::Events.subscribe(StandardId::Events::AUTHENTICATION_FAILED) { |payload| failures << payload }

      body = grant(password)

      expect(response).to have_http_status(:bad_request)
      expect(body).to eq("error" => "invalid_grant", "error_description" => "Invalid username or password")
      expect(failures.map { |f| f[:error_code] }).to include("identifier_unverified")
    end
  end

  it "mints for an unverified identifier when the gate is off (default), so hosts must opt in" do
    StandardId::EmailIdentifier.find_by!(value: email).update!(verified_at: nil)

    grant(password)

    expect(response).to have_http_status(:ok)
  end
end
