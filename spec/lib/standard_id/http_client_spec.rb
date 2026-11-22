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

      http = Net::HTTP.new("example.com", 443)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:start).and_call_original

      described_class.post_form("https://example.com/token", { key: "value" })

      expect(http.open_timeout).to eq(5)
      expect(http.read_timeout).to eq(10)
    end

    it "configures timeouts on get_with_bearer requests" do
      stub_request(:get, "https://example.com/api")
        .to_return(status: 200, body: "{}")

      http = Net::HTTP.new("example.com", 443)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:start).and_call_original

      described_class.get_with_bearer("https://example.com/api", "token")

      expect(http.open_timeout).to eq(5)
      expect(http.read_timeout).to eq(10)
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

    it "blocks requests to 172.31.x.x (private class B boundary)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["172.31.255.254"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "allows requests to 172.32.0.1 (outside private class B)" do
      allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["172.32.0.1"])
      stub_request(:post, "https://example.com/token").to_return(status: 200, body: "{}")

      response = described_class.post_form("https://example.com/token", {})
      expect(response).to be_a(Net::HTTPSuccess)
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

    it "blocks requests to IPv6 unique local (fc00::)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["fc00::1"])

      expect {
        described_class.post_form("https://evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "blocks requests to IPv6 link-local (fe80::)" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["fe80::1"])

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

    it "raises on empty DNS resolution" do
      allow(Resolv).to receive(:getaddresses).with("nxdomain.example.com").and_return([])

      expect {
        described_class.post_form("https://nxdomain.example.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError, "Could not resolve host")
    end

    it "rejects file:// scheme" do
      expect {
        described_class.post_form("file:///etc/passwd", {})
      }.to raise_error(StandardId::HttpClient::SsrfError, "Only http and https schemes are allowed")
    end

    it "rejects ftp:// scheme" do
      expect {
        described_class.get_with_bearer("ftp://evil.com/file", "token")
      }.to raise_error(StandardId::HttpClient::SsrfError, "Only http and https schemes are allowed")
    end

    it "rejects URLs without a scheme" do
      expect {
        described_class.post_form("evil.com/token", {})
      }.to raise_error(StandardId::HttpClient::SsrfError)
    end

    it "preserves the hostname for TLS SNI when connecting to resolved IP" do
      allow(Resolv).to receive(:getaddresses).with("example.com").and_return(["93.184.216.34"])
      stub_request(:post, "https://example.com/token").to_return(status: 200, body: "{}")

      http = Net::HTTP.new("example.com", 443)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:start).and_call_original

      described_class.post_form("https://example.com/token", {})

      # Net::HTTP.new receives the hostname (for SNI), not the resolved IP
      expect(Net::HTTP).to have_received(:new).with("example.com", 443)
      # ipaddr= pins the TCP connection to the resolved IP
      expect(http.ipaddr).to eq("93.184.216.34")
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

      http = Net::HTTP.new("secure.example.com", 443)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:start).and_call_original

      described_class.get_with_bearer("https://secure.example.com/api", "token")

      expect(http.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
    end

    it "does not enable SSL for HTTP connections" do
      stub_request(:get, "http://example.com/api")
        .to_return(status: 200, body: "{}")

      http = Net::HTTP.new("example.com", 80)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:start).and_call_original

      described_class.get_with_bearer("http://example.com/api", "token")

      expect(http.use_ssl?).to be false
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
      expect(JSON.parse(response.body)["access_token"]).to eq("token123")
    end

    it "returns error responses from the server" do
      stub_request(:post, endpoint)
        .with(body: hash_including("client_id" => "test_id"))
        .to_return(status: 400, body: '{"error":"invalid_request"}')

      response = described_class.post_form(endpoint, params)

      expect(response).to be_a(Net::HTTPBadRequest)
    end

    it "handles network errors gracefully" do
      stub_request(:post, endpoint).to_timeout

      expect {
        described_class.post_form(endpoint, params)
      }.to raise_error(Net::OpenTimeout)
    end

    it "keeps repeated keys when the form is an Array of pairs" do
      stub_request(:post, endpoint).to_return(status: 200, body: "{}")

      described_class.post_form(endpoint, [["scope", "openid"], ["scope", "email"], ["client_id", "test_id"]])

      expect(WebMock).to have_requested(:post, endpoint).with(body: "scope=openid&scope=email&client_id=test_id")
    end
  end

  describe ".get_with_bearer" do
    let(:endpoint) { "https://api.example.com/userinfo" }
    let(:access_token) { "test_access_token_123" }

    before do
      allow(Resolv).to receive(:getaddresses).with("api.example.com").and_return(["93.184.216.34"])
    end

    it "sends GET request with Bearer token" do
      stub_request(:get, endpoint)
        .with(headers: { "Authorization" => "Bearer test_access_token_123" })
        .to_return(status: 200, body: '{"id":"user123"}')

      response = described_class.get_with_bearer(endpoint, access_token)

      expect(response).to be_a(Net::HTTPSuccess)
      expect(JSON.parse(response.body)["id"]).to eq("user123")
    end

    it "returns error responses from the server" do
      stub_request(:get, endpoint)
        .with(headers: { "Authorization" => "Bearer test_access_token_123" })
        .to_return(status: 401, body: '{"error":"invalid_token"}')

      response = described_class.get_with_bearer(endpoint, access_token)

      expect(response).to be_a(Net::HTTPUnauthorized)
    end

    it "handles network errors gracefully" do
      stub_request(:get, endpoint).to_timeout

      expect {
        described_class.get_with_bearer(endpoint, access_token)
      }.to raise_error(Net::OpenTimeout)
    end
  end

  describe "network_wrapper" do
    let(:calls) { [] }

    before do
      stub_request(:post, "https://example.com/token").to_return(status: 200, body: "{}")
      stub_request(:get, "https://example.com/api").to_return(status: 200, body: "{}")
      recorded = calls
      StandardId.config.network_wrapper = lambda do |provider:, &block|
        recorded << provider
        block.call
      end
    end

    it "runs the request directly when no wrapper is configured" do
      StandardId.config.network_wrapper = nil

      response = described_class.post_form("https://example.com/token", {})

      expect(response.code).to eq("200")
    end

    it "passes the provider to the wrapper and returns the block's response" do
      response = described_class.post_form("https://example.com/token", { a: 1 }, provider: :google)

      expect(calls).to eq([:google])
      expect(response.code).to eq("200")
    end

    it "wraps get_with_bearer" do
      described_class.get_with_bearer("https://example.com/api", "token", provider: :apple)

      expect(calls).to eq([:apple])
      expect(WebMock).to have_requested(:get, "https://example.com/api").with(headers: { "Authorization" => "Bearer token" })
    end

    it "still takes the form as bare keywords, as callers written before provider: pass it" do
      stub_request(:post, "https://example.com/token").with(body: { "access_token" => "abc" }).to_return(status: 200, body: "{}")

      response = described_class.post_form("https://example.com/token", access_token: "abc")

      expect(response.code).to eq("200")
      expect(calls).to eq([:standard_id])
    end

    it "takes bare-keyword form fields alongside provider:" do
      stub_request(:post, "https://example.com/token").with(body: { "access_token" => "abc" }).to_return(status: 200, body: "{}")

      described_class.post_form("https://example.com/token", access_token: "abc", provider: :google)

      expect(calls).to eq([:google])
    end

    it "sends an explicit Hash form unchanged, including a field named provider" do
      stub_request(:post, "https://example.com/token").with(body: { "provider" => "x", "a" => "1" }).to_return(status: 200, body: "{}")

      described_class.post_form("https://example.com/token", { provider: "x", a: "1" }, provider: :google)

      expect(calls).to eq([:google])
    end

    it "names :standard_id when the caller names no provider" do
      described_class.post_form("https://example.com/token", {})
      described_class.get_with_bearer("https://example.com/api", "token")

      expect(calls).to eq(%i[standard_id standard_id])
    end

    it "wraps start_connection, which plugins call through send for a JWKS" do
      uri, resolved_ip = described_class.send(:validate_url!, "https://example.com/api")

      response = described_class.send(:start_connection, uri, resolved_ip: resolved_ip, provider: :google) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end

      expect(calls).to eq([:google])
      expect(response.code).to eq("200")
    end

    it "keeps start_connection callable without provider:, as older plugins call it" do
      uri, resolved_ip = described_class.send(:validate_url!, "https://example.com/api")

      described_class.send(:start_connection, uri, resolved_ip: resolved_ip) { |http| http.request(Net::HTTP::Get.new(uri)) }

      expect(calls).to eq([:standard_id])
    end

    it "accepts a wrapper that declares no provider keyword" do
      StandardId.config.network_wrapper = ->(&block) { block.call }

      expect(described_class.post_form("https://example.com/token", {}, provider: :google).code).to eq("200")
    end

    it "propagates an error raised by the request through the wrapper" do
      stub_request(:post, "https://example.com/token").to_timeout
      seen = []
      StandardId.config.network_wrapper = lambda do |provider:, &block|
        block.call
      rescue StandardError => e
        seen << e.class
        raise
      end

      expect {
        described_class.post_form("https://example.com/token", {}, provider: :google)
      }.to raise_error(Net::OpenTimeout)
      expect(seen).to eq([Net::OpenTimeout])
    end

    it "propagates an error the wrapper raises itself, without making the request" do
      circuit_open = Class.new(StandardError)
      StandardId.config.network_wrapper = ->(provider:, &_block) { raise circuit_open, "#{provider} open" }

      expect {
        described_class.post_form("https://example.com/token", {}, provider: :google)
      }.to raise_error(circuit_open, "google open")
      expect(WebMock).not_to have_requested(:post, "https://example.com/token")
    end

    it "validates the URL before the wrapper runs, so an SSRF refusal never counts against a provider" do
      allow(Resolv).to receive(:getaddresses).with("evil.com").and_return(["127.0.0.1"])

      expect {
        described_class.post_form("https://evil.com/token", {}, provider: :google)
      }.to raise_error(StandardId::HttpClient::SsrfError)
      expect(calls).to be_empty
    end
  end
end
