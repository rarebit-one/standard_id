require "rails_helper"

# WebAuthentication#require_recent_authentication! and the /step_up page
# (StandardId::StepUp). The dummy app's SensitiveController is guarded with
# `within: 5.minutes`.
RSpec.describe "Web step-up authentication", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:email) { "web-step-up-#{SecureRandom.hex(4)}@example.com" }
  let(:password) { "Sup3r-secret!" }
  let!(:account) { create_account_with_password(email: email, password: password) }

  before do
    StandardId.config.step_up.enabled = true
    capture_passwordless_codes
  end

  def sign_in_with_password
    http_post "/login", params: { login: { email: email, password: password }, redirect_uri: "/after" }
    expect(response).to redirect_to("/after")
  end

  def browser_session
    StandardId::BrowserSession.where(account: account).order(:created_at).last
  end

  def events_for(*names)
    events = []
    subs = names.map { |name| StandardId::Events.subscribe(name) { |e| events << name } }
    yield
    events
  ensure
    subs&.each { |s| StandardId::Events.unsubscribe(s) }
  end

  it "stamps authenticated_at on a password sign-in" do
    freeze_time do
      sign_in_with_password
      expect(browser_session.authenticated_at).to eq(Time.current)
    end
  end

  it "lets a fresh sign-in through" do
    sign_in_with_password
    http_get "/sensitive"

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("sensitive for #{account.id}")
  end

  it "sends a signed-out visitor to login" do
    http_get "/sensitive"

    expect(response).to redirect_to(%r{/login})
  end

  context "when the session is stale" do
    before do
      sign_in_with_password
      travel 10.minutes
    end

    it "redirects to /step_up" do
      http_get "/sensitive"

      expect(response).to redirect_to("/step_up")
    end

    it "redirects a non-GET too, without remembering it" do
      http_patch "/sensitive"

      expect(response).to redirect_to("/step_up")
    end

    it "steps up with a code and the password, then returns to the guarded page" do
      http_get "/sensitive"
      http_get "/step_up"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("step-up-send-form").and include(email)

      events = events_for(StandardId::Events::STEP_UP_STARTED, StandardId::Events::STEP_UP_SUCCEEDED) do
        http_post "/step_up"
        expect(response).to redirect_to("/step_up")
        http_get "/step_up"
        expect(response.body).to include("step-up-verify-form").and include('name="password"')

        freeze_time do
          http_patch "/step_up", params: { code: issued_otp_code(email), password: password }
          expect(response).to redirect_to("http://www.example.com/sensitive")
          expect(browser_session.authenticated_at).to eq(Time.current)
        end
      end
      expect(events).to eq([StandardId::Events::STEP_UP_STARTED, StandardId::Events::STEP_UP_SUCCEEDED])

      http_get "/sensitive"
      expect(response).to have_http_status(:ok)
    end

    it "re-renders with an error, and stays stale, on a wrong code" do
      http_post "/step_up"
      events = events_for(StandardId::Events::STEP_UP_FAILED) do
        http_patch "/step_up", params: { code: "000000", password: password }
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("The code is invalid or has expired")
      expect(events).to eq([StandardId::Events::STEP_UP_FAILED])
      http_get "/sensitive"
      expect(response).to redirect_to("/step_up")
    end

    it "refuses the right code with a wrong password" do
      http_post "/step_up"
      http_patch "/step_up", params: { code: issued_otp_code(email), password: "Wr0ng-password!" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("The password is incorrect")
    end
  end

  it "asks a remember-me session to step up: a cookie is not a fresh proof" do
    http_post "/login", params: { login: { email: email, password: password, remember_me: "1" }, redirect_uri: "/after" }
    remember = cookies["remember_token"]
    reset!
    cookies["remember_token"] = remember

    http_get "/sensitive"

    expect(response).to redirect_to("/step_up")
    expect(browser_session.authenticated_at).to be_nil
  end

  it "uses c.step_up.url when set" do
    StandardId.config.step_up.url = "/auth/step_up"
    sign_in_with_password
    travel 10.minutes

    http_get "/sensitive"
    expect(response).to redirect_to("/auth/step_up")
  end

  context "when c.step_up.enabled is false (the default)" do
    before { StandardId.config.step_up.enabled = false }

    it "does not draw /step_up" do
      sign_in_with_password
      http_get "/step_up"

      expect(response).to have_http_status(:not_found)
    end

    it "makes the guard raise a ConfigurationError instead of passing or refusing silently" do
      sign_in_with_password

      expect { http_get "/sensitive" }.to raise_error(StandardId::ConfigurationError, /c\.step_up\.enabled/)
    end
  end
end
