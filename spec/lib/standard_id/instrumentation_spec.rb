require "rails_helper"

RSpec.describe StandardId::Instrumentation do
  let(:request) { instance_double("ActionDispatch::Request") }

  # Records start/finish order so nesting can be asserted, the way a tracing
  # subscriber (Sentry/OTel span per event) would see it.
  def capture_instrumentation
    log = []
    listener = Class.new do
      define_method(:start) { |name, _id, payload| log << [:start, name, payload.dup] }
      define_method(:finish) { |name, _id, payload| log << [:finish, name, payload.dup] }
    end.new
    subscription = ActiveSupport::Notifications.subscribe(described_class::PATTERN, listener)
    yield
    log
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  def build_flow(audience:, account:)
    concrete = Class.new(StandardId::Oauth::TokenGrantFlow) do
      attr_accessor :_test_account

      def authenticate!; end
      def subject_id; "sub-123"; end
      def client_id; "cid-abc"; end
      def token_scope; "read"; end
      def grant_type; "password"; end
      def token_expiry; 30.minutes; end
      def supports_refresh_token?; false; end
      def maybe_persist_session_for_token!; end
      def token_account; @_test_account; end
    end
    flow = concrete.new({ audience: audience }, request)
    flow._test_account = account
    flow
  end

  it "matches its own events and none of StandardId::Events' names" do
    described_class::EVENTS.each { |name| expect(name).to match(described_class::PATTERN) }
    expect(StandardId::Events.namespaced_event_name(:authentication_succeeded)).not_to match(described_class::PATTERN)
  end

  describe "around a token grant with an audience→profile binding" do
    before do
      allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return("admin_kit" => "PlatformProfile")
      allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(nil)
      allow(StandardId.config.oauth).to receive(:allowed_audiences).and_return(["admin_kit"])
    end

    it "emits authenticate, then binding with the resolver call nested inside it" do
      account = double("Account", profiles: [])
      flow = build_flow(audience: "admin_kit", account: account)

      log = capture_instrumentation do
        expect { flow.execute }.to raise_error(StandardId::NoBoundProfileError)
      end

      expect(log.map { |phase, name, _| [phase, name] }).to eq([
        [:start, described_class::AUTHENTICATE],
        [:finish, described_class::AUTHENTICATE],
        [:start, described_class::AUDIENCE_PROFILE_BINDING],
        [:start, described_class::AUDIENCE_PROFILE_RESOLVE],
        [:finish, described_class::AUDIENCE_PROFILE_RESOLVE],
        [:finish, described_class::AUDIENCE_PROFILE_BINDING]
      ])

      auth_payload = log[1][2]
      expect(auth_payload).to include(grant_type: "password")
      expect(auth_payload).to have_key(:flow)

      binding_payload = log[5][2]
      expect(binding_payload).to include(grant_type: "password", audience: ["admin_kit"])
      expect(binding_payload[:exception_object]).to be_a(StandardId::NoBoundProfileError)

      resolve_payload = log[4][2]
      expect(resolve_payload).to include(audience: "admin_kit")
      expect(resolve_payload[:exception_object]).to be_a(StandardId::NoBoundProfileError)
    end
  end

  it "wraps RefreshTokenFlow#authenticate! (and reports its failure)" do
    flow = StandardId::Oauth::RefreshTokenFlow.new({ client_id: "cid", refresh_token: "rtok" }, request)
    allow(flow).to receive(:authenticate!).and_raise(StandardId::InvalidGrantError, "nope")

    log = capture_instrumentation do
      expect { flow.execute }.to raise_error(StandardId::InvalidGrantError)
    end

    finish = log.find { |phase, name, _| phase == :finish && name == described_class::AUTHENTICATE }
    expect(finish[2]).to include(flow: "StandardId::Oauth::RefreshTokenFlow", grant_type: "refresh_token")
    expect(finish[2][:exception_object]).to be_a(StandardId::InvalidGrantError)
  end

  it "emits the resolver event when AudienceProfileResolver.resolve! is called directly" do
    allow(StandardId.config.oauth).to receive(:audience_profile_types).and_return("web" => "PlatformProfile")
    allow(StandardId.config.oauth).to receive(:audience_profile_resolver).and_return(->(**) { :profile })

    log = capture_instrumentation do
      expect(StandardId::Oauth::AudienceProfileResolver.resolve!(account: double, audience: "web")).to eq(:profile)
    end

    expect(log.map(&:second)).to eq([described_class::AUDIENCE_PROFILE_RESOLVE] * 2)
  end
end
