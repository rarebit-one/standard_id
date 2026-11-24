require "rails_helper"

# authentication.password.failed is published when a password is checked
# against an existing credential and does not match, at each of the three
# password logins. A login that names no credential publishes only
# authentication.attempt.failed.
RSpec.describe "authentication.password.failed", type: :request do
  let(:email) { "pwfail-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "Sup3r-secret!" }

  def capture(event)
    events = []
    sub = StandardId::Events.subscribe(event) { |e| events << e.payload }
    yield
    events
  ensure
    StandardId::Events.unsubscribe(sub) if sub
  end

  def credential
    StandardId::PasswordCredential.find_by!(login: email)
  end

  shared_examples "a login that reports a wrong password" do
    it "publishes it, with ids and no password, before authentication.attempt.failed" do
      order = []
      failed_sub = StandardId::Events.subscribe(StandardId::Events::AUTHENTICATION_FAILED) { order << :attempt_failed }
      events = capture(StandardId::Events::PASSWORD_VALIDATION_FAILED) do
        password_sub = StandardId::Events.subscribe(StandardId::Events::PASSWORD_VALIDATION_FAILED) { order << :password_failed }
        log_in("Wr0ng-password!")
      ensure
        StandardId::Events.unsubscribe(failed_sub, password_sub)
      end

      expect(events.size).to eq(1)
      payload = events.first
      expect(payload).to include(account_lookup: email, credential_id: credential.id, error_code: "invalid_password")
      expect(payload[:account].id).to eq(credential.account.id)
      expect(payload.values.map(&:to_s)).not_to include("Wr0ng-password!", password)
      expect(order).to eq(%i[password_failed attempt_failed])
    end

    it "is not published for the right password" do
      expect(capture(StandardId::Events::PASSWORD_VALIDATION_FAILED) { log_in(password) }).to be_empty
    end

    it "is not published for an unknown login" do
      events = capture(StandardId::Events::PASSWORD_VALIDATION_FAILED) do
        log_in(password, login: "nobody-#{SecureRandom.hex(4)}@example.com")
      end

      expect(events).to be_empty
    end
  end

  describe "web login (sign_in_account)" do
    before { create_account_with_password(email: email, password: password) }

    def log_in(pw, login: email)
      http_post "/login", params: { login: { email: login, password: pw }, redirect_uri: "/after" }
    end

    it_behaves_like "a login that reports a wrong password"
  end

  describe "OAuth password grant" do
    before { create_account_with_password(email: email, password: password) }

    def log_in(pw, login: email)
      post "/api/oauth/token", params: { grant_type: "password", username: login, password: pw, client_id: "test-client" }, as: :json
    end

    it_behaves_like "a login that reports a wrong password"
  end

  describe "email + password API (Authentication.call)" do
    before do
      StandardId.config.email_password.enabled = true
      http_post_json("/api/auth/register", params: { name: "Nova", email: email, password: password })
      http_post_json("/api/auth/verify-email", params: { email: email, code: issued_otp_code(email), password: password })
    end

    def log_in(pw, login: email)
      http_post_json("/api/auth/login", params: { email: login, password: pw })
    end

    it_behaves_like "a login that reports a wrong password"
  end
end
