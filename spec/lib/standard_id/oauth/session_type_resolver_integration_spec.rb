require "rails_helper"

# Integration spec for `config.session.session_type_resolver` against OAuth
# token grants. Replicates the admin_kit / sidekick-web workaround described
# at sidekick-web/config/initializers/standard_id_events.rb: a native mobile
# app authenticates via the passwordless_otp OAuth grant, and the host app
# wants a DeviceSession persisted (so the session surfaces under "Mobile
# Sessions" in the UI) instead of nothing.
RSpec.describe "OAuth session_type_resolver integration" do
  let(:request) do
    instance_double(
      ActionDispatch::Request,
      remote_ip: "10.0.0.5",
      user_agent: "AdminKit/1.0 Android"
    )
  end

  before do
    allow(StandardId.config).to receive(:passwordless_email_sender).and_return(nil)
    allow(StandardId.config).to receive(:passwordless_sms_sender).and_return(nil)
  end

  after { StandardId.config.session.session_type_resolver = nil }

  def create_challenge(connection:, username:, code: "987654")
    StandardId::CodeChallenge.create!(
      realm: "authentication",
      channel: connection,
      target: username,
      code: code,
      expires_at: 10.minutes.from_now,
      ip_address: "10.0.0.5",
      user_agent: "AdminKit/1.0 Android"
    )
  end

  def setup_account_for_admin_kit
    account = Account.create!(name: "Admin", email: "admin@example.com")
    StandardId::EmailIdentifier.create!(
      account: account,
      value: "admin@example.com",
      verified_at: Time.current
    )
    create_challenge(connection: "email", username: "admin@example.com", code: "987654")
    account
  end

  def build_params
    {
      grant_type: "passwordless_otp",
      client_id: "admin-kit-client",
      connection: "email",
      username: "admin@example.com",
      otp: "987654",
      audience: "admin_kit"
    }
  end

  it "persists no session by default (back-compat)" do
    setup_account_for_admin_kit

    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    expect {
      StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute
    }.not_to change(StandardId::DeviceSession, :count)
  end

  it "persists a DeviceSession when resolver returns :device for :oauth_token_issued" do
    account = setup_account_for_admin_kit

    StandardId.config.session.session_type_resolver = lambda { |request:, account:, flow:|
      next nil unless flow == :oauth_token_issued
      # Admin-kit identification: either audience claim (carried via request
      # params in real flows) or user-agent sniff.
      request.user_agent.to_s.include?("AdminKit") ? :device : nil
    }

    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    expect {
      StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute
    }.to change(StandardId::DeviceSession, :count).by(1)

    session = StandardId::DeviceSession.order(:created_at).last
    expect(session.account).to eq(account)
    expect(session.device_agent).to eq("AdminKit/1.0 Android")
    expect(session.ip_address).to eq("10.0.0.5")
    expect(session.expires_at).to be_within(1.minute).of(StandardId::DeviceSession.expiry)
  end

  it "reuses the same DeviceSession row for repeated admin_kit token requests (upsert)" do
    setup_account_for_admin_kit

    StandardId.config.session.session_type_resolver = ->(**) { :device }

    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute

    # Second token request — create a fresh challenge because the first was consumed
    create_challenge(connection: "email", username: "admin@example.com", code: "111111")

    params_second = build_params.merge(otp: "111111")

    expect {
      StandardId::Oauth::PasswordlessOtpFlow.new(params_second, request).execute
    }.not_to change(StandardId::DeviceSession, :count)
  end

  it "raises ConfigurationError if resolver returns an unsupported class for :oauth_token_issued" do
    setup_account_for_admin_kit

    StandardId.config.session.session_type_resolver = ->(**) { :service }

    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    # ConfigurationError is re-raised (not swallowed) so misconfiguration is loud.
    expect {
      StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute
    }.to raise_error(StandardId::ConfigurationError, /only :browser and :device are supported/)
  end
end
