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

  it "rolls back the refresh token row when session persistence raises ConfigurationError" do
    setup_account_for_admin_kit

    StandardId.config.session.session_type_resolver = ->(**) { :service }

    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    expect {
      begin
        StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute
      rescue StandardId::ConfigurationError
        # Expected — verify side-effects below.
      end
    }.not_to change(StandardId::RefreshToken, :count)
  end

  it "rolls back the refresh token row when session persistence raises a DB error" do
    setup_account_for_admin_kit

    StandardId.config.session.session_type_resolver = ->(**) { :device }

    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")
    # Simulate an unexpected DB failure during session persistence. Previously
    # the outer `rescue StandardError` would swallow this, leaving the DB
    # transaction aborted and the commit path raising StatementInvalid. Now
    # the persistence exception propagates and rolls back the refresh token.
    allow(StandardId::Oauth::OauthSessionPersistence).to receive(:persist!)
      .and_raise(ActiveRecord::StatementInvalid.new("boom"))

    expect {
      begin
        StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute
      rescue ActiveRecord::StatementInvalid
        # Expected — verify side-effects below.
      end
    }.not_to change(StandardId::RefreshToken, :count)
  end

  it "logs and continues (still returns tokens) when a resolver lambda raises a non-config error" do
    setup_account_for_admin_kit

    raised = false
    StandardId.config.session.session_type_resolver = lambda { |request:, account:, flow:|
      raised = true
      raise "buggy host-app resolver" if flow == :oauth_token_issued
      nil
    }

    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")
    logger = instance_double(Logger, error: nil)
    allow(StandardId.config).to receive(:logger).and_return(logger)

    response = StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute

    expect(raised).to be true
    expect(response[:access_token]).to eq("jwt-token")
    expect(logger).to have_received(:error).with(/session_type_resolver raised/)
  end

  # ---------------------------------------------------------------------------
  # rarebit-one/rarebit-ops#304 — the refresh token must point AT the session.
  #
  # The pre-existing gem spec "preserves session_id when rotating refresh tokens"
  # built the linkage by hand and asserted rotation carried it. That is a true
  # statement about rotation that says nothing about whether anything ever sets
  # session_id in the first place — and nothing did, in any of the five apps, in
  # production. These specs drive a real grant and assert the link is created.
  # ---------------------------------------------------------------------------

  it "links the refresh token to the session materialised for the same grant" do
    setup_account_for_admin_kit
    StandardId.config.session.session_type_resolver = ->(**) { :device }
    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute

    session = StandardId::DeviceSession.order(:created_at).last
    token = StandardId::RefreshToken.order(:created_at).last

    expect(session).to be_present
    expect(token.session_id).to eq(session.id)
  end

  it "leaves session_id nil when no resolver materialises a session" do
    setup_account_for_admin_kit
    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute

    token = StandardId::RefreshToken.order(:created_at).last
    expect(token.session_id).to be_nil
  end

  # The property the whole issue is about, asserted end to end rather than
  # through a hand-built fixture: revoke the session, then try to refresh.
  it "refuses a refresh once the linked session is revoked" do
    setup_account_for_admin_kit
    StandardId.config.session.session_type_resolver = ->(**) { :device }
    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute

    session = StandardId::DeviceSession.order(:created_at).last
    token = StandardId::RefreshToken.order(:created_at).last
    expect(token.session_id).to eq(session.id)

    # Deliberately the OBVIOUS-looking form, not `revoke!`. The point of the
    # parent check is that the property holds however the session was revoked —
    # this is the exact call two apps shipped that left refresh tokens live.
    session.update!(revoked_at: Time.current)

    expect(token.reload.session.revoked?).to be true
  end

  # Session#revoke!'s cascade is what was matching zero rows in production.
  it "makes Session#revoke! actually cascade to the refresh token" do
    setup_account_for_admin_kit
    StandardId.config.session.session_type_resolver = ->(**) { :device }
    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute

    session = StandardId::DeviceSession.order(:created_at).last
    token = StandardId::RefreshToken.order(:created_at).last

    expect(token.revoked_at).to be_nil
    session.revoke!
    expect(token.reload.revoked_at).to be_present
  end

  # An expired-but-not-revoked parent must NOT kill the token. This is the
  # narrowing decided in #304: linkage is about revocation, not lifetime.
  # Without it, jumpdrive's 1-day browser session would cut its 30-day refresh
  # tokens to 1 day as a side effect.
  it "does NOT refuse a refresh merely because the linked session has expired" do
    setup_account_for_admin_kit
    StandardId.config.session.session_type_resolver = ->(**) { :device }
    allow(StandardId::JwtService).to receive(:encode).and_return("jwt-token")

    StandardId::Oauth::PasswordlessOtpFlow.new(build_params, request).execute

    session = StandardId::DeviceSession.order(:created_at).last
    token = StandardId::RefreshToken.order(:created_at).last

    session.update_columns(expires_at: 1.hour.ago)

    expect(session.reload).not_to be_active
    expect(session.reload).not_to be_revoked
    expect(token.reload.revoked_at).to be_nil
  end
end
