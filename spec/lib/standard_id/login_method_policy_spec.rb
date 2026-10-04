require "rails_helper"

RSpec.describe StandardId::LoginMethodPolicy do
  let(:account) { Account.create!(name: "Policy", email: "policy-#{SecureRandom.hex(4)}@example.com") }
  let(:request) { instance_double(ActionDispatch::Request) }

  def with_policy(policy)
    allow(StandardId.config).to receive(:login_method_policy).and_return(policy)
  end

  def enforce(**overrides)
    described_class.enforce!(account: account, auth_method: :password, flow: :web_password, request: request, **overrides)
  end

  def capture_denied_events
    events = []
    subscription = StandardId::Events.subscribe(StandardId::Events::AUTHENTICATION_METHOD_DENIED) { |event| events << event }
    yield
    events
  ensure
    StandardId::Events.unsubscribe(subscription)
  end

  it "defaults to no policy" do
    expect(StandardId.config.login_method_policy).to be_nil
    expect(described_class.configured?).to be(false)
  end

  it "allows everything when no policy is configured, without publishing" do
    events = capture_denied_events { expect(enforce).to be(true) }
    expect(events).to be_empty
  end

  it "allows when the policy returns a truthy value" do
    with_policy(->(**) { :ok })
    expect(enforce).to be(true)
  end

  [false, nil].each do |value|
    it "refuses with the generic message when the policy returns #{value.inspect}" do
      with_policy(->(**) { value })

      expect { enforce }.to raise_error(StandardId::LoginMethodDenied, StandardId::LoginMethodDenied::DEFAULT_MESSAGE)
    end
  end

  it "refuses with the policy's own message when it raises LoginMethodDenied" do
    with_policy(->(**) { raise StandardId::LoginMethodDenied, "Staff must sign in with the org IdP" })

    expect { enforce(auth_method: :social, provider: "google", flow: :web_social) }
      .to raise_error(StandardId::LoginMethodDenied) { |error|
        expect(error.message).to eq("Staff must sign in with the org IdP")
        expect(error.auth_method).to eq(:social)
        expect(error.provider).to eq("google")
        expect(error.flow).to eq(:web_social)
        expect(error).to be_a(StandardId::AuthenticationDenied)
        expect(error.oauth_error_code).to eq(:access_denied)
        expect(error.http_status).to eq(:forbidden)
      }
  end

  it "uses the generic message when the policy raises LoginMethodDenied without one" do
    with_policy(->(**) { raise StandardId::LoginMethodDenied })

    expect { enforce }.to raise_error(StandardId::LoginMethodDenied, StandardId::LoginMethodDenied::DEFAULT_MESSAGE)
  end

  it "publishes AUTHENTICATION_METHOD_DENIED on refusal" do
    with_policy(->(**) { false })

    events = capture_denied_events do
      expect { enforce(auth_method: :social, provider: "google", flow: :oauth_social_callback) }.to raise_error(StandardId::LoginMethodDenied)
    end

    expect(events.size).to eq(1)
    expect(events.first[:account]).to eq(account)
    expect(events.first[:auth_method]).to eq("social")
    expect(events.first[:provider]).to eq("google")
    expect(events.first[:flow]).to eq("oauth_social_callback")
    expect(events.first[:error_message]).to eq(StandardId::LoginMethodDenied::DEFAULT_MESSAGE)
  end

  it "lists the event among the security events" do
    expect(StandardId::Events::SECURITY_EVENTS).to include(StandardId::Events::AUTHENTICATION_METHOD_DENIED)
  end

  it "passes only the keywords the policy declares" do
    received = nil
    with_policy(->(account:, flow:) { received = { account:, flow: } })

    enforce(flow: :web_signup)

    expect(received).to eq(account: account, flow: :web_signup)
  end

  it "passes the full context to a policy that takes **kwargs" do
    received = nil
    with_policy(->(**context) { received = context })

    enforce(auth_method: "social", provider: :google, flow: :web_social)

    expect(received).to eq(account: account, auth_method: :social, provider: "google", request: request, flow: :web_social)
  end

  it "normalises a missing auth_method to :unspecified" do
    received = nil
    with_policy(->(auth_method:) { received = auth_method })

    enforce(auth_method: nil)

    expect(received).to eq(:unspecified)
  end

  it "accepts any object responding to #call" do
    policy = Class.new { def call(auth_method:, **) = auth_method == :password }.new
    with_policy(policy)

    expect(enforce).to be(true)
    expect { enforce(auth_method: :passwordless) }.to raise_error(StandardId::LoginMethodDenied)
  end

  it "raises ConfigurationError for a non-callable policy" do
    with_policy(true)

    expect { enforce }.to raise_error(StandardId::ConfigurationError, /login_method_policy/)
  end

  it "lets other exceptions from the policy propagate (fails closed)" do
    with_policy(->(**) { raise ArgumentError, "bug" })

    expect { enforce }.to raise_error(ArgumentError, "bug")
  end

  describe "boot-time signature validation" do
    it "rejects a policy declaring an unknown keyword" do
      allow(StandardId.config).to receive(:login_method_policy).and_return(->(account:, mechanism:) { true })

      expect { StandardId::Config::CallableValidator.validate! }
        .to raise_error(StandardId::ConfigurationError, /login_method_policy.*mechanism/)
    end

    it "accepts a policy declaring a subset of the keywords" do
      allow(StandardId.config).to receive(:login_method_policy).and_return(->(account:, provider:) { true })

      expect { StandardId::Config::CallableValidator.validate! }.not_to raise_error
    end
  end
end
