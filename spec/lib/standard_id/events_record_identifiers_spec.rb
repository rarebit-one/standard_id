# frozen_string_literal: true

require "rails_helper"

# The emitter half of rarebit-one/rarebit-ops#296.
#
# This gem publishes whole ActiveRecord objects on the notification bus, and a
# record serialises with all its attributes — which is how `password_digest`,
# `token_digest`, `lookup_hash` and the plaintext passwordless OTP reached
# append-only audit rows across the estate. 3,007 such rows on one app, and the
# table refuses UPDATE by design, so they cannot be repaired.
#
# `standard_audit` 0.11.0 closed its own write path. It cannot close this one:
# a host's own subscribers receive the same payloads and may put them in Sentry
# context, structured logs, or their own tables. Publishing the identifier
# alongside the record is what lets a subscriber stop needing the record.
#
# The default is deliberately ADDITIVE. Removing the records in the same step
# would break every consumer's `actor_extractor` at once — all five apps
# configure one, reading `payload[:actor] || payload[:current_account] ||
# payload[:account]` and calling `to_global_id` on the result.
RSpec.describe "StandardId::Events record identifiers" do
  let!(:account) { Account.create!(name: "Probe", email: "probe@example.com") }

  def captured_payload(&publish)
    payload = nil
    subscriber = ActiveSupport::Notifications.subscribe(/standard_id\./) do |*, captured|
      payload = captured
    end
    publish.call
    payload
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "by default" do
    subject(:payload) do
      captured_payload { StandardId::Events.publish(:authentication_succeeded, account: account) }
    end

    it "adds the id alongside the record" do
      expect(payload[:account_id]).to eq(account.id)
    end

    # A GlobalID carries the class as well as the id, which is what the audit
    # gems key on — `account_id` alone cannot tell an Account from anything else
    # with the same primary key.
    it "adds the global id alongside the record" do
      expect(payload[:account_gid]).to eq(account.to_global_id.to_s)
    end

    # The load-bearing half of "additive". If this ever fails, every consumer's
    # actor_extractor stops resolving an actor and audit rows go anonymous —
    # silently, because a nil actor is not an error.
    it "still publishes the record itself" do
      expect(payload[:account]).to eq(account)
    end

    it "leaves non-record values exactly as they were" do
      payload = captured_payload do
        StandardId::Events.publish(:authentication_succeeded, account: account, reason: "otp", attempts: 2)
      end

      expect(payload[:reason]).to eq("otp")
      expect(payload[:attempts]).to eq(2)
      expect(payload).not_to have_key(:reason_id)
    end
  end

  # The migration path: a host flips this once its subscribers read the
  # identifiers, and can prove nothing depends on the records before committing.
  describe "with config.events.publish_records = false" do
    around do |example|
      StandardId.config.events.publish_records = false
      example.run
    ensure
      StandardId.config.events.publish_records = true
    end

    it "publishes the identifiers without the record" do
      payload = captured_payload { StandardId::Events.publish(:authentication_succeeded, account: account) }

      expect(payload[:account_id]).to eq(account.id)
      expect(payload[:account_gid]).to eq(account.to_global_id.to_s)
      expect(payload).not_to have_key(:account)
    end

    # The point of the whole change, asserted on the payload as a whole rather
    # than on key absence: what leaks is the VALUE. A record left in under a
    # different key would satisfy `not_to have_key(:account)` and leak anyway.
    it "puts no record attributes on the bus at all" do
      account.update!(email: "leaky@example.com") if account.respond_to?(:email=)

      payload = captured_payload { StandardId::Events.publish(:authentication_succeeded, account: account) }

      expect(payload.values.none? { |v| v.is_a?(::ActiveRecord::Base) }).to be(true)
    end
  end

  describe "with config.events.publish_record_identifiers = false" do
    around do |example|
      StandardId.config.events.publish_record_identifiers = false
      example.run
    ensure
      StandardId.config.events.publish_record_identifiers = true
    end

    it "restores the pre-#296 payload exactly" do
      payload = captured_payload { StandardId::Events.publish(:authentication_succeeded, account: account) }

      expect(payload[:account]).to eq(account)
      expect(payload).not_to have_key(:account_id)
      expect(payload).not_to have_key(:account_gid)
    end
  end

  # An event must never fail because of the metadata this feature adds to it.
  # `to_global_id` raises on an unpersisted record, and publishing is on the
  # authentication path.
  it "does not raise when a record has no global id" do
    unsaved = Account.new

    expect {
      payload = captured_payload { StandardId::Events.publish(:authentication_succeeded, account: unsaved) }
      expect(payload[:account]).to eq(unsaved)
    }.not_to raise_error
  end

  # `current_account` is injected into EVERY event by enrich_payload, so it is
  # the key most likely to carry a record into a host's subscriber — and the one
  # a host cannot avoid by changing its own publish calls.
  it "adds identifiers for the implicitly-injected current_account too" do
    Current.account = account
    payload = captured_payload { StandardId::Events.publish(:authentication_succeeded) }

    expect(payload[:current_account_id]).to eq(account.id)
    expect(payload[:current_account_gid]).to eq(account.to_global_id.to_s)
  ensure
    Current.account = nil
  end
end
