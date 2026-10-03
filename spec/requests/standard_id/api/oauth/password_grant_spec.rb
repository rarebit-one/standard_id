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
end
