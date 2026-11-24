require "rails_helper"

# oauth.token.refreshed (a refresh_token grant rotated its token) and
# session.refreshed (a token grant reused the device's DeviceSession and moved
# its expiry forward). Both fire on every refresh, so neither is auditable.
RSpec.describe "Refresh events", type: :request do
  let(:email) { "refresh-events-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "Sup3r-secret!" }
  let!(:account) { create_account_with_password(email: email, password: password) }

  def capture(*names)
    events = []
    subs = StandardId::Events.subscribe(*names) { |e| events << [e.short_name, e.payload] }
    yield
    events
  ensure
    StandardId::Events.unsubscribe(subs) if subs
  end

  def password_grant
    post "/api/oauth/token", params: { grant_type: "password", username: email, password: password, client_id: "test-client" }, as: :json
    response.parsed_body
  end

  def refresh(refresh_token)
    post "/api/oauth/token", params: { grant_type: "refresh_token", refresh_token: refresh_token, client_id: "test-client" }, as: :json
    response.parsed_body
  end

  describe "oauth.token.refreshed" do
    it "is published once per rotation, with ids and no token" do
      old_token = password_grant["refresh_token"]
      old_record = StandardId::RefreshToken.order(:created_at).last

      body = nil
      events = capture(StandardId::Events::OAUTH_TOKEN_REFRESHED) { body = refresh(old_token) }

      expect(response).to have_http_status(:ok)
      expect(events.size).to eq(1)
      payload = events.first.last
      new_record = StandardId::RefreshToken.order(:created_at).last
      expect(payload).to include(client_id: "test-client", account_id: account.id,
                                 previous_refresh_token_id: old_record.id, refresh_token_id: new_record.id, graced: false)
      expect(payload[:account].id).to eq(account.id)
      expect(payload.values.map(&:to_s)).not_to include(old_token, body["refresh_token"], body["access_token"])
    end

    it "is not published for the grant that first issues the token" do
      expect(capture(StandardId::Events::OAUTH_TOKEN_REFRESHED) { password_grant }).to be_empty
    end

    it "is not published when the refresh is refused" do
      old_token = password_grant["refresh_token"]
      refresh(old_token)

      events = capture(StandardId::Events::OAUTH_TOKEN_REFRESHED) { refresh(old_token) } # reuse

      expect(response).to have_http_status(:bad_request)
      expect(events).to be_empty
    end

    it "rolls the rotation back when a subscriber raises, as oauth.token.issued does" do
      old_token = password_grant["refresh_token"]
      old_record = StandardId::RefreshToken.order(:created_at).last
      sub = StandardId::Events.subscribe(StandardId::Events::OAUTH_TOKEN_REFRESHED) { raise "subscriber down" }
      begin
        expect {
          begin
            refresh(old_token)
          rescue RuntimeError
            nil
          end
        }.not_to change(StandardId::RefreshToken, :count)
      ensure
        StandardId::Events.unsubscribe(sub)
      end

      expect(old_record.reload).not_to be_revoked
      expect(refresh(old_token)["refresh_token"]).to be_present
    end
  end

  describe "session.refreshed" do
    before do
      StandardId.config.session.session_type_resolver = ->(flow:, **) { flow == :oauth_token_issued ? :device : nil }
    end

    it "is published when a refresh reuses the device session and extends it" do
      old_token = password_grant["refresh_token"]
      device_session = StandardId::DeviceSession.find_by!(account_id: account.id)
      device_session.update_columns(expires_at: 1.minute.from_now)
      previous_expires_at = device_session.reload.expires_at

      events = capture(StandardId::Events::SESSION_REFRESHED) { refresh(old_token) }

      expect(events.size).to eq(1)
      payload = events.first.last
      expect(payload[:session].id).to eq(device_session.id)
      expect(payload[:account].id).to eq(account.id)
      expect(payload[:previous_expires_at]).to be_within(1.second).of(previous_expires_at)
      expect(payload[:expires_at]).to be > previous_expires_at
      expect(payload[:grant_type]).to eq("refresh_token")
    end

    it "is not published when the grant creates the device session" do
      expect(capture(StandardId::Events::SESSION_REFRESHED) { password_grant }).to be_empty
    end

    it "is not published without a device session resolver" do
      StandardId.config.session.session_type_resolver = nil
      old_token = password_grant["refresh_token"]

      expect(capture(StandardId::Events::SESSION_REFRESHED) { refresh(old_token) }).to be_empty
    end

    it "is not published for a grant that rolls back, and a raising subscriber does not fail the grant" do
      old_token = password_grant["refresh_token"]

      rolled_back = capture(StandardId::Events::SESSION_REFRESHED) do
        sub = StandardId::Events.subscribe(StandardId::Events::OAUTH_TOKEN_ISSUED) { raise "issued subscriber down" }
        begin
          refresh(old_token)
        rescue RuntimeError
          nil
        ensure
          StandardId::Events.unsubscribe(sub)
        end
      end
      expect(rolled_back).to be_empty

      allow(Rails.error).to receive(:report)
      sub = StandardId::Events.subscribe(StandardId::Events::SESSION_REFRESHED) { raise "refreshed subscriber down" }
      begin
        body = refresh(old_token)
        expect(response).to have_http_status(:ok)
        expect(body["refresh_token"]).to be_present
      ensure
        StandardId::Events.unsubscribe(sub)
      end
      expect(Rails.error).to have_received(:report).with(an_instance_of(RuntimeError), hash_including(handled: true))
    end
  end

  it "keeps both out of Events.auditable" do
    %w[oauth.token.refreshed session.refreshed].each do |short|
      name = "standard_id.#{short}"
      expect(StandardId::Events.auditable.any? { |p| p.is_a?(Regexp) ? p.match?(name) : p == name }).to be(false)
    end
  end
end
