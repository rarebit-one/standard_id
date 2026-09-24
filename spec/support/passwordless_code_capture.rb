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
      codes << [event[:identifier], event[:code_challenge]&.code] unless event[:skip_sender]
    end
    (@passwordless_code_subscriptions ||= []) << subscription
    codes
  end
end

RSpec.configure do |config|
  config.include PasswordlessCodeCaptureHelper

  config.after(:each) do
    Array(@passwordless_code_subscriptions).each { |sub| ActiveSupport::Notifications.unsubscribe(sub) }
  end
end
