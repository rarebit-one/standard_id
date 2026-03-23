require "rails_helper"

RSpec.describe StandardId::HttpClient do
  before do
    allow(Resolv).to receive(:getaddresses).and_return(["93.184.216.34"])
  end

  describe "timeout configuration" do
    it "defines OPEN_TIMEOUT at the class level" do
      expect(described_class::OPEN_TIMEOUT).to eq(5)
    end

    it "defines READ_TIMEOUT at the class level" do
      expect(described_class::READ_TIMEOUT).to eq(10)
    end

    it "configures timeouts on post_form requests" do
      stub_request(:post, "https://example.com/token")
        .to_return(status: 200, body: "{}")

      expect(Net::HTTP).to receive(:start)
        .with("example.com", 443,
              use_ssl: true, open_timeout: 5, read_timeout: 10,
              verify_mode: OpenSSL::SSL::VERIFY_PEER)
        .and_call_original

      described_class.post_form("https://example.com/token", { key: "value" })
    end

    it "configures timeouts on get_with_bearer requests" do
      stub_request(:get, "https://example.com/api")
        .to_return(status: 200, body: "{}")

      expect(Net::HTTP).to receive(:start)
        .with("example.com", 443,
              use_ssl: true, open_timeout: 5, read_timeout: 10,
              verify_mode: OpenSSL::SSL::VERIFY_PEER)
        .and_call_original

      described_class.get_with_bearer("https://example.com/api", "token")
    end
  end

  describe "SSRF protection" do
    it "blocks requests to 127.0.0.1 (loopback)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["127.0.0.1"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError, "Requests to private/internal addresses are not allowed")
    end

    it "blocks requests to 10.x.x.x (private class A)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["10.0.0.1"])

      expect {
        described_class.get_with_bearer("https://evil.com/api", "token")
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "blocks requests to 172.16.x.x (private class B)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["172.16.0.1"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "blocks requests to 192.168.x.x (private class C)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["192.168.1.1"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "blocks requests to 169.254.x.x (link-local)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["169.254.169.254"])

      expect {
        described_class.get_with_bearer("https://evil.com/api", "token")
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "blocks requests to 0.0.0.0" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["0.0.0.0"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "blocks requests to IPv6 loopback (::1)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["::1"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "blocks requests to IPv6 unique local (fd00::)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["fd00::1"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "blocks when any resolved address is private" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["93.184.216.34", "127.0.0.1"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "allows requests to public IP addresses" do
      allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["93.184.216.34"])

      stub_request(:post, "https://example.com/token")
        .to_return(status: 200, body: "{}")

      response = described_class.post_form("https://example.com/token", { key: "value" })

      expect(response).to be_a(Net::HTTPSuccess)
    end

    it "does not reveal blocked IP ranges in error message" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["10.0.0.1"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError, "Requests to private/internal addresses are not allowed")
    end
  end

  describe "SSL verification" do
    it "sets VERIFY_PEER for HTTPS connections" do
      stub_request(:get, "https://secure.example.com/api")
        .to_return(status: 200, body: "{}")

      expect(Net::HTTP).to receive(:start)
        .with("secure.example.com", 443,
              use_ssl: true, open_timeout: 5, read_timeout: 10,
              verify_mode: OpenSSL::SSL::VERIFY_PEER)
        .and_call_original

      described_class.get_with_bearer("https://secure.example.com/api", "token")
    end

    it "does not set verify_mode for HTTP connections" do
      stub_request(:get, "http://example.com/api")
        .to_return(status: 200, body: "{}")

      expect(Net::HTTP).to receive(:start)
        .with("example.com", 80,
              use_ssl: false, open_timeout: 5, read_timeout: 10)
        .and_call_original

      described_class.get_with_bearer("http://example.com/api", "token")
    end
  end

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
