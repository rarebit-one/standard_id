require "standard_id/testing/otp_helpers"

# Records the OTP codes the passwordless strategy hands to delivery — i.e. every
# PASSWORDLESS_CODE_GENERATED event a subscriber should deliver (skip_sender
# events are left out). Replaces the removed passwordless_*_sender stubs:
#
#   codes = capture_passwordless_codes
#   post "/api/passwordless/start", params: { ... }
#   expect(codes).to contain_exactly(["user@example.com", kind_of(String)])
#
# Entries are [identifier, code]; #events on the returned array holds the raw
# event payloads (including skipped ones). Unsubscribed after each example.
module PasswordlessCodeCaptureHelper
  def capture_passwordless_codes
    codes = []
    events = []
    codes.define_singleton_method(:events) { events }
    subscription = StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_GENERATED) do |event|
      events << event
      codes << [event[:identifier], StandardId::Passwordless.issued_code(event)] unless event[:skip_sender]
    end
    (@passwordless_code_subscriptions ||= []) << subscription
    codes
  end

  # The raw code of the last OTP issued so far in this example, to +identifier+
  # when given. A CodeChallenge stores only an HMAC of its code, so specs can
  # no longer read it back with `StandardId::CodeChallenge.last.code`; the
  # recorder below captures every code from PASSWORDLESS_CODE_GENERATED (as a
  # delivery subscriber would), including skip_sender ones.
  def issued_otp_code(identifier = nil)
    issued = Array(@issued_otp_codes)
    issued = issued.select { |entry| entry.identifier == identifier } if identifier
    issued.last&.code || raise("No one-time code was issued#{" to #{identifier}" if identifier} in this example")
  end

  # Every event the start path publishes on the way to delivery (requested,
  # generated, sent). Empty means the request never reached code creation.
  def capture_passwordless_start_events
    events = []
    subscriptions = StandardId::Events.subscribe(
      StandardId::Events::PASSWORDLESS_CODE_REQUESTED,
      StandardId::Events::PASSWORDLESS_CODE_GENERATED,
      StandardId::Events::PASSWORDLESS_CODE_SENT
    ) { |event| events << event }
    (@passwordless_code_subscriptions ||= []).concat(subscriptions)
    events
  end
end

RSpec.configure do |config|
  config.include PasswordlessCodeCaptureHelper

  # Recorder for #issued_otp_code. An example that swaps the notifier
  # (clear_event_subscribers!) drops it, and gets no codes, by design.
  config.before(:each) do
    @issued_otp_codes = []
    (@passwordless_code_subscriptions ||= []) << StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_GENERATED) do |event|
      code = StandardId::Passwordless.issued_code(event)
      next if code.blank?

      @issued_otp_codes << StandardId::Testing::OtpHelpers::IssuedCode.new(
        identifier: event[:identifier], channel: event[:channel], realm: event[:realm], code: code
      )
    end
  end

  config.after(:each) do
    Array(@passwordless_code_subscriptions).each { |sub| ActiveSupport::Notifications.unsubscribe(sub) }
  end
end
