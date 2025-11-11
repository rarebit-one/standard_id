require "rails_helper"

RSpec.describe StandardId::HttpClient do
  describe ".post_form" do
    let(:endpoint) { "https://example.com/token" }
    let(:params) { { client_id: "test_id", client_secret: "test_secret", grant_type: "authorization_code" } }

    it "posts form data to the endpoint" do
      stub_request(:post, endpoint)
        .with(
          body: hash_including("client_id" => "test_id", "client_secret" => "test_secret", "grant_type" => "authorization_code"),
          headers: { "Content-Type" => "application/x-www-form-urlencoded" }
        )
        .to_return(status: 200, body: '{"access_token":"token123"}', headers: { "Content-Type" => "application/json" })

      response = described_class.post_form(endpoint, params)

      expect(response).to be_a(Net::HTTPSuccess)
      expect(response.code).to eq("200")
      expect(JSON.parse(response.body)["access_token"]).to eq("token123")
    end

    it "returns error responses from the server" do
      stub_request(:post, endpoint)
        .with(body: hash_including("client_id" => "test_id"))
        .to_return(status: 400, body: '{"error":"invalid_request"}', headers: { "Content-Type" => "application/json" })

      response = described_class.post_form(endpoint, params)

      expect(response).to be_a(Net::HTTPBadRequest)
      expect(response.code).to eq("400")
      expect(JSON.parse(response.body)["error"]).to eq("invalid_request")
    end

    it "handles network errors gracefully" do
      stub_request(:post, endpoint).to_timeout

      expect {
        described_class.post_form(endpoint, params)
      }.to raise_error(Net::OpenTimeout)
    end

    it "encodes form parameters correctly" do
      special_params = { key: "value with spaces", other: "special&chars=true" }

      stub_request(:post, endpoint)
        .with(body: "key=value+with+spaces&other=special%26chars%3Dtrue")
        .to_return(status: 200)

      response = described_class.post_form(endpoint, special_params)

      expect(response).to be_a(Net::HTTPSuccess)
    end
  end

  describe ".get_with_bearer" do
    let(:endpoint) { "https://api.example.com/userinfo" }
    let(:access_token) { "test_access_token_123" }

    it "sends GET request with Bearer token" do
      stub_request(:get, endpoint)
        .with(headers: { "Authorization" => "Bearer test_access_token_123" })
        .to_return(status: 200, body: '{"id":"user123","email":"user@example.com"}', headers: { "Content-Type" => "application/json" })

      response = described_class.get_with_bearer(endpoint, access_token)

      expect(response).to be_a(Net::HTTPSuccess)
      expect(response.code).to eq("200")
      user_data = JSON.parse(response.body)
      expect(user_data["id"]).to eq("user123")
      expect(user_data["email"]).to eq("user@example.com")
    end

    it "returns error responses from the server" do
      stub_request(:get, endpoint)
        .with(headers: { "Authorization" => "Bearer test_access_token_123" })
        .to_return(status: 401, body: '{"error":"invalid_token"}', headers: { "Content-Type" => "application/json" })

      response = described_class.get_with_bearer(endpoint, access_token)

      expect(response).to be_a(Net::HTTPUnauthorized)
      expect(response.code).to eq("401")
      expect(JSON.parse(response.body)["error"]).to eq("invalid_token")
    end

    it "uses HTTPS when endpoint scheme is https" do
      https_endpoint = "https://secure.example.com/api"

      stub_request(:get, https_endpoint)
        .with(headers: { "Authorization" => "Bearer #{access_token}" })
        .to_return(status: 200, body: "{}")

      response = described_class.get_with_bearer(https_endpoint, access_token)

      expect(response).to be_a(Net::HTTPSuccess)
    end

    it "uses HTTP when endpoint scheme is http" do
      http_endpoint = "http://insecure.example.com/api"

      stub_request(:get, http_endpoint)
        .with(headers: { "Authorization" => "Bearer #{access_token}" })
        .to_return(status: 200, body: "{}")

      response = described_class.get_with_bearer(http_endpoint, access_token)

      expect(response).to be_a(Net::HTTPSuccess)
    end

    it "handles network errors gracefully" do
      stub_request(:get, endpoint).to_timeout

      expect {
        described_class.get_with_bearer(endpoint, access_token)
      }.to raise_error(Net::OpenTimeout)
    end

    it "includes the Authorization header correctly" do
      stub_request(:get, endpoint)
        .with(headers: { "Authorization" => "Bearer test_access_token_123" })
        .to_return(status: 200, body: "{}")

      response = described_class.get_with_bearer(endpoint, access_token)

      expect(response).to be_a(Net::HTTPSuccess)
    end

    it "handles different bearer token formats" do
      long_token = "a" * 500

      stub_request(:get, endpoint)
        .with(headers: { "Authorization" => "Bearer #{long_token}" })
        .to_return(status: 200, body: "{}")

      response = described_class.get_with_bearer(endpoint, long_token)

      expect(response).to be_a(Net::HTTPSuccess)
    end
  end
end
