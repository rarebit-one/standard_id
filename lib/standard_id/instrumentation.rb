require "active_support/notifications"

module StandardId
  # ActiveSupport::Notifications hooks around the expensive, opaque steps of
  # the OAuth token endpoint, so hosts can attach tracing spans (Sentry,
  # OpenTelemetry, Datadog) or timing metrics without prepending onto private
  # gem methods.
  #
  # Names follow the Rails `<event>.<library>` convention (like
  # `process_action.action_controller`), deliberately distinct from the
  # `standard_id.<domain>.<event>` names StandardId::Events publishes: these
  # are timing hooks, not audit events, and must not reach audit subscribers
  # listening on `standard_id.*`.
  #
  # Every event is a block instrument, so subscribers get start/finish (and
  # `:exception` / `:exception_object` in the payload when the step raised).
  # Events nest: AUDIENCE_PROFILE_RESOLVE fires inside AUDIENCE_PROFILE_BINDING.
  #
  # Subscribe to all of them with:
  #
  #   ActiveSupport::Notifications.subscribe(StandardId::Instrumentation::PATTERN) { |event| ... }
  module Instrumentation
    # TokenGrantFlow#authenticate! — client authentication plus grant
    # validation (for refresh_token: JWT decode + token row lookup + reuse
    # detection). Payload: :flow (class name), :grant_type.
    AUTHENTICATE = "authenticate.standard_id".freeze

    # TokenGrantFlow#enforce_audience_profile_binding! — the account load and
    # profile resolution for audience→profile binding. Fires on every token
    # grant, including when no binding is configured (then it is a no-op).
    # Payload: :flow, :grant_type, :audience (Array<String>).
    AUDIENCE_PROFILE_BINDING = "audience_profile_binding.standard_id".freeze

    # Oauth::AudienceProfileResolver.resolve! — just the resolver call (the
    # host's `oauth.audience_profile_resolver` or the built-in strict lookup).
    # Payload: :audience (String).
    AUDIENCE_PROFILE_RESOLVE = "audience_profile_resolve.standard_id".freeze

    EVENTS = [AUTHENTICATE, AUDIENCE_PROFILE_BINDING, AUDIENCE_PROFILE_RESOLVE].freeze

    # Matches every instrumentation event above and nothing StandardId::Events
    # publishes.
    PATTERN = /\.standard_id\z/

    def self.instrument(name, payload = {}, &)
      ActiveSupport::Notifications.instrument(name, payload, &)
    end
  end
end
