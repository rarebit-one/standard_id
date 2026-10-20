# Suite-wide isolation for the process-wide event subscriber registry.
#
# StandardId registers its subscriptions ONCE per process, in two places:
#
#   * `StandardId::Engine`'s `subscribers` initializer attaches the bundled
#     `Events::Subscribers::*` classes.
#   * `AccountLocking` / `AccountStatus` subscribe inline from their
#     `included do` block, behind a `@subscribed` guard flag that is set on
#     first include and never reset.
#
# Both register against the global `ActiveSupport::Notifications.notifier`.
# The `clear_event_subscribers!` helper below swaps that notifier for a brand
# new `Fanout` so an example can assert against a known-empty subscriber set —
# but it used to swap it *permanently*. Because the guard flags stay `true`,
# the enforcement subscriptions could never be rebuilt, so the first example to
# call the helper silently disarmed account lock/status enforcement for every
# later example in the process.
#
# In declaration order the affected files happened to run before any caller of
# the helper, so the suite reported green while asserting nothing. Under
# `config.order = :random` it surfaced as six failures in `account_locking_spec`
# and `account_status_spec` ("expected StandardId::AccountLockedError but
# nothing was raised").
#
# Wrapping every example in a snapshot/restore of the notifier makes the swap
# example-scoped: `clear_event_subscribers!` still hands the caller a clean
# fanout, and the original — carrying the process-wide subscriptions — is put
# back afterwards, whether or not the example remembered to clean up. Mirrors
# `config_isolation.rb`, which does the same for `StandardId.config`.
module StandardIdEventsTestHelper
  # Replace the global notifier with an empty one for the rest of this example.
  # Safe to call freely: the hook below restores the real notifier afterwards,
  # so it can no longer leak into the rest of the suite.
  def clear_event_subscribers!
    ActiveSupport::Notifications.notifier = ActiveSupport::Notifications::Fanout.new
  end
end

RSpec.configure do |config|
  config.include StandardIdEventsTestHelper

  # Load the dummy account model BEFORE any example runs. Outside CI the dummy
  # app does not eager-load, so `Account` (and with it the `included` blocks of
  # AccountStatus / AccountLocking, which subscribe the enforcement guards
  # behind their one-shot flags) is loaded by whichever example touches it
  # first. If that example has already swapped the notifier via
  # `clear_event_subscribers!`, the guards subscribe to the throwaway Fanout,
  # the flags stay true, and enforcement is silently disarmed for the rest of
  # the process — seed-dependent (e.g. `--seed 6` with account_status_spec +
  # account_status_subscriber_spec), and invisible in CI where eager_load is on.
  config.before(:suite) { Account }

  config.around(:each) do |example|
    saved_notifier = ActiveSupport::Notifications.notifier
    example.run
  ensure
    ActiveSupport::Notifications.notifier = saved_notifier
  end
end
