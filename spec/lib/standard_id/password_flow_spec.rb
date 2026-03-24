require "rails_helper"

RSpec.describe StandardId::Oauth::PasswordFlow do
  let(:request) { instance_double("ActionDispatch::Request", remote_ip: "127.0.0.1", user_agent: "RSpec") }
  let(:client_id) { "client_123" }
  let(:client_secret) { "s3cr3t" }
  let(:username) { "user@example.com" }
  let(:password) { "password1" }
  let(:scope) { nil }
  let(:audience) { "https://api.example.com" }
  let(:base_params) { { client_id: client_id, username: username, password: password, audience: audience } }
  let(:params) { base_params.merge(scope: scope) }

  let(:account) { instance_double("Account", id: 77) }

  describe "#authenticate!" do
    it "authenticates with username/password without client_secret" do
      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account)

      flow = described_class.new(params, request)
      expect { flow.authenticate! }.not_to raise_error
    end

    it "authenticates with username/password and client_secret (valid client)" do
      allow_any_instance_of(described_class)
        .to receive(:validate_client_secret!)
        .with(client_id, client_secret)
        .and_return(true)

      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account)

      flow = described_class.new(params.merge(client_secret: client_secret), request)
      expect { flow.authenticate! }.not_to raise_error
    end

    it "raises InvalidGrantError when account auth fails" do
      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(nil)

      flow = described_class.new(params, request)
      expect { flow.authenticate! }.to raise_error(StandardId::InvalidGrantError)
    end

    it "validates scope tokens when scope is present" do
      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account)

      flow = described_class.new(params.merge(scope: "read write"), request)
      expect { flow.authenticate! }.not_to raise_error
    end

    it "raises InvalidScopeError for invalid scope tokens" do
      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account)

      flow = described_class.new(params.merge(scope: "read invalid@scope"), request)
      expect { flow.authenticate! }.to raise_error(StandardId::InvalidScopeError)
    end
  end

  describe "private API" do
    before do
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({})
      allow(StandardId.config.oauth).to receive(:default_token_lifetime).and_return(8.hours.to_i)
      allow_any_instance_of(described_class)
        .to receive(:persist_refresh_token!)
    end

    it "exposes subject_id, client_id, token_scope (default), grant_type, audience, expiry and refresh support" do
      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account)

      flow = described_class.new(params, request)
      flow.authenticate!

      expect(flow.send(:subject_id)).to eq(77)
      expect(flow.send(:client_id)).to eq(client_id)
      expect(flow.send(:token_scope)).to eq("read") # default scope
      expect(flow.send(:grant_type)).to eq("password")
      expect(flow.send(:audience)).to eq(audience)
      expect(flow.send(:supports_refresh_token?)).to be(true)
      expect(flow.send(:token_expiry)).to eq(8.hours)

      token = flow.send(:generate_refresh_token)
      expect(token).to be_a(String)
      expect(token.length).to be > 0
    end

    it "uses provided scope when present" do
      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account)

      # Avoid NotImplementedError from validate_requested_scope!
      allow_any_instance_of(described_class)
        .to receive(:validate_requested_scope!)
        .and_return(true)

      flow = described_class.new(params.merge(scope: "read write"), request)
      flow.authenticate!

      expect(flow.send(:token_scope)).to eq("read write")
    end

    it "prefers flow-specific lifetime when configured" do
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({ password: 2.hours.to_i })
      allow(StandardId.config.oauth).to receive(:default_token_lifetime).and_return(8.hours.to_i)

      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account)

      flow = described_class.new(params, request)
      flow.authenticate!

      expect(flow.send(:token_expiry)).to eq(2.hours)
    end
  end

  describe "custom scope claims" do
    let(:client_application) { instance_double("StandardId::ClientApplication") }
    let(:account_with_status) { instance_double("Account", id: 77, locked?: false, inactive?: false) }

    before do
      allow(StandardId::ClientApplication).to receive(:find_by).and_return(client_application)
      allow(StandardId.config.oauth).to receive(:scope_claims).and_return({ "read" => [:tenant_id] })
      allow_any_instance_of(described_class)
        .to receive(:persist_refresh_token!)
    end

    it "passes account and client context to the resolver" do
      allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({
        tenant_id: ->(client:, account:) { "#{client.object_id}-#{account.id}" }
      })

      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account_with_status)

      encoded_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        encoded_payloads << payload
        "jwt-token"
      end

      result = described_class.new(params, request).execute
      expect(result[:access_token]).to eq("jwt-token")
      expect(encoded_payloads.first[:tenant_id]).to eq("#{client_application.object_id}-#{account_with_status.id}")
    end
  end

  describe "custom_claims config" do
    let(:client_application) { instance_double("StandardId::ClientApplication") }
    let(:account_with_status) { double("Account", id: 77, locked?: false, inactive?: false, channel_id: "ch-42") }

    before do
      allow(StandardId::ClientApplication).to receive(:find_by).and_return(client_application)
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({})
      allow(StandardId.config.oauth).to receive(:default_token_lifetime).and_return(8.hours.to_i)
      allow(StandardId.account_class).to receive(:find_by).and_return(account_with_status)
      allow_any_instance_of(described_class)
        .to receive(:persist_refresh_token!)
      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account_with_status)
    end

    it "adds custom claims to the JWT payload when custom_claims is configured" do
      allow(StandardId.config.oauth).to receive(:custom_claims).and_return(
        ->(account:, **) { { channel_id: account.channel_id } }
      )

      encoded_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        encoded_payloads << payload
        "jwt-token"
      end

      described_class.new(params, request).execute

      access_payload = encoded_payloads.first
      expect(access_payload[:channel_id]).to eq("ch-42")
    end

    it "does not add custom claims when custom_claims is nil" do
      allow(StandardId.config.oauth).to receive(:custom_claims).and_return(nil)

      encoded_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        encoded_payloads << payload
        "jwt-token"
      end

      described_class.new(params, request).execute

      access_payload = encoded_payloads.first
      expect(access_payload).not_to have_key(:channel_id)
    end

    it "prevents custom claims from overriding reserved JWT keys" do
      allow(StandardId.config.oauth).to receive(:custom_claims).and_return(
        ->(**) { { sub: "evil-override", exp: 9999999999, channel_id: "ch-ok" } }
      )

      encoded_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        encoded_payloads << payload
        "jwt-token"
      end

      described_class.new(params, request).execute

      access_payload = encoded_payloads.first
      expect(access_payload[:sub]).to eq(77)
      expect(access_payload[:channel_id]).to eq("ch-ok")
      expect(access_payload).not_to have_key(:exp) # exp is set by encode, not payload
    end

    it "merges custom claims with scope claims" do
      allow(StandardId.config.oauth).to receive(:scope_claims).and_return({ "read" => [:tenant_id] })
      allow(StandardId.config.oauth).to receive(:claim_resolvers).and_return({
        tenant_id: ->(account:, **) { "tenant-#{account.id}" }
      })
      allow(StandardId.config.oauth).to receive(:custom_claims).and_return(
        ->(account:, **) { { channel_id: account.channel_id } }
      )

      encoded_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, _|
        encoded_payloads << payload
        "jwt-token"
      end

      described_class.new(params, request).execute

      access_payload = encoded_payloads.first
      expect(access_payload[:tenant_id]).to eq("tenant-77")
      expect(access_payload[:channel_id]).to eq("ch-42")
    end
  end

  describe "audience in refresh token" do
    let(:account_with_status) { instance_double("Account", id: 77, locked?: false, inactive?: false) }
    before do
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({})
      allow(StandardId.config.oauth).to receive(:default_token_lifetime).and_return(8.hours.to_i)
      allow_any_instance_of(described_class)
        .to receive(:persist_refresh_token!)
    end

    it "includes audience in refresh token payload" do
      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account_with_status)

      refresh_token_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, opts|
        if payload[:grant_type] == "refresh_token"
          refresh_token_payloads << payload
        end
        "jwt-token"
      end

      described_class.new(params, request).execute

      expect(refresh_token_payloads.first[:aud]).to eq(audience)
    end

    it "omits audience from refresh token when not provided" do
      params_without_audience = base_params.except(:audience).merge(scope: scope)

      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account_with_status)

      refresh_token_payloads = []
      allow(StandardId::JwtService).to receive(:encode) do |payload, opts|
        if payload[:grant_type] == "refresh_token"
          refresh_token_payloads << payload
        end
        "jwt-token"
      end

      described_class.new(params_without_audience, request).execute

      expect(refresh_token_payloads.first).not_to have_key(:aud)
    end
  end

  describe "audience validation" do
    let(:account_with_status) { instance_double("Account", id: 77, locked?: false, inactive?: false) }

    before do
      allow(StandardId.config.oauth).to receive(:token_lifetimes).and_return({})
      allow(StandardId.config.oauth).to receive(:default_token_lifetime).and_return(8.hours.to_i)
      allow_any_instance_of(described_class)
        .to receive(:authenticate_account)
        .with(username, password)
        .and_return(account_with_status)
      allow_any_instance_of(described_class)
        .to receive(:persist_refresh_token!)
    end

    it "allows any audience when allowed_audiences is empty" do
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return([])
      allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

      expect {
        described_class.new(params.merge(audience: "anything"), request).execute
      }.not_to raise_error
    end

    it "allows valid audience when allowed_audiences is configured" do
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(%w[companion_kit admin_kit harness])
      allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

      expect {
        described_class.new(params.merge(audience: "harness"), request).execute
      }.not_to raise_error
    end

    it "raises InvalidRequestError for invalid audience" do
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(%w[companion_kit admin_kit])

      expect {
        described_class.new(params.merge(audience: "unknown"), request).execute
      }.to raise_error(StandardId::InvalidRequestError, "Invalid audience: unknown")
    end

    it "allows blank audience even when allowed_audiences is configured" do
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(%w[companion_kit admin_kit])
      allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

      params_without_audience = base_params.except(:audience).merge(scope: scope)

      expect {
        described_class.new(params_without_audience, request).execute
      }.not_to raise_error
    end

    it "allows array audience when all values are valid" do
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(%w[companion_kit admin_kit harness])
      allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

      expect {
        described_class.new(params.merge(audience: %w[companion_kit harness]), request).execute
      }.not_to raise_error
    end

    it "raises InvalidRequestError when any array audience value is invalid" do
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(%w[companion_kit admin_kit])

      expect {
        described_class.new(params.merge(audience: %w[companion_kit unknown]), request).execute
      }.to raise_error(StandardId::InvalidRequestError, "Invalid audience: unknown")
    end

    it "raises InvalidRequestError listing all invalid audiences" do
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(%w[companion_kit])

      expect {
        described_class.new(params.merge(audience: %w[foo bar]), request).execute
      }.to raise_error(StandardId::InvalidRequestError, "Invalid audience: foo, bar")
    end
  end
end
