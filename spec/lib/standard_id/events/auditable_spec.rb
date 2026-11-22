require "rails_helper"

RSpec.describe "StandardId::Events.auditable" do
  subject(:auditable) { StandardId::Events.auditable }

  def audited?(event_constant)
    name = StandardId::Events.namespaced_event_name(event_constant)
    auditable.any? { |pattern| pattern.is_a?(Regexp) ? pattern.match?(name) : pattern == name }
  end

  # standard_audit's Configuration#subscribe_to took exactly one pattern
  # before it grew a splat, so the documented wiring calls it once per pattern.
  it "wires into a single-argument subscribe_to, one pattern per call, as the README shows" do
    config = Class.new do
      attr_reader :subscriptions

      def initialize
        @subscriptions = []
      end

      def subscribe_to(pattern)
        @subscriptions << pattern
      end
    end.new

    StandardId::Events.auditable.each { |pattern| config.subscribe_to(pattern) }

    expect(config.subscriptions).to eq(auditable)
  end

  it "is frozen, and so is every pattern in it" do
    expect(auditable).to be_frozen
    expect(auditable).to all(be_frozen)
  end

  it "holds only Regexps and full event-name Strings" do
    expect(auditable).to all(be_a(Regexp).or(be_a(String)))
    strings = auditable.grep(String)
    expect(strings).to all(start_with("standard_id."))
    expect(strings.map { |s| s.delete_prefix("standard_id.") }).to all(be_in(StandardId::Events::ALL_EVENTS))
  end

  it "keeps everything the apps subscribed to before the list existed" do
    expect(auditable).to include(
      /\Astandard_id\.authentication\./,
      "standard_id.session.created",
      "standard_id.session.revoked",
      "standard_id.session.expired",
      /\Astandard_id\.account\./,
      /\Astandard_id\.social\./,
      /\Astandard_id\.passwordless\./
    )
  end

  it "covers credential, token-theft, revocation and client-registration events" do
    %w[
      CREDENTIAL_PASSWORD_CREATED CREDENTIAL_PASSWORD_RESET_INITIATED CREDENTIAL_PASSWORD_RESET_COMPLETED
      CREDENTIAL_PASSWORD_CHANGED CREDENTIAL_CLIENT_SECRET_CREATED CREDENTIAL_CLIENT_SECRET_ROTATED
      CREDENTIAL_CLIENT_SECRET_REVOKED OAUTH_REFRESH_TOKEN_REUSE_DETECTED OAUTH_TOKEN_REVOKED
      OAUTH_AUDIENCE_MISMATCH OAUTH_CLIENT_REGISTERED OAUTH_CLIENT_UPDATED OAUTH_CLIENT_DEREGISTERED
    ].each do |constant|
      expect(audited?(StandardId::Events.const_get(constant))).to be(true), "#{constant} is not auditable"
    end
  end

  it "leaves out per-request and high-volume events" do
    %w[SESSION_VALIDATING SESSION_VALIDATED OAUTH_TOKEN_ISSUED OAUTH_TOKEN_REFRESHED
       OAUTH_REFRESH_TOKEN_REUSE_GRACED CREDENTIAL_PASSWORD_REHASHED].each do |constant|
      expect(audited?(StandardId::Events.const_get(constant))).to be(false), "#{constant} should not be auditable"
    end
  end

  it "subscribes through ActiveSupport::Notifications to exactly the matching events" do
    received = []
    subscribers = auditable.map { |pattern| ActiveSupport::Notifications.subscribe(pattern) { |name, *| received << name } }

    StandardId::Events.publish(StandardId::Events::CREDENTIAL_PASSWORD_RESET_COMPLETED)
    StandardId::Events.publish(StandardId::Events::AUTHENTICATION_FAILED)
    StandardId::Events.publish(StandardId::Events::SESSION_VALIDATED)

    expect(received).to eq(%w[standard_id.credential.password.reset_completed standard_id.authentication.attempt.failed])
  ensure
    subscribers&.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
  end
end
