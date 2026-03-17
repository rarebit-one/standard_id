module StandardId
  # Sets Sentry user context from the current authenticated account.
  #
  # This is a standalone concern that host apps can include in their
  # ApplicationController to automatically set Sentry user context
  # for each request. It eliminates the need for apps to write
  # their own SentryContext boilerplate.
  #
  # Safe to include even when the Sentry gem is not installed -- the
  # callback is a no-op if `Sentry` is not defined.
  #
  # Extra fields can be added via the `sentry_context` config option:
  #
  #   StandardId.configure do |c|
  #     c.sentry_context = ->(account, session) {
  #       { email: account.email, username: account.try(:display_name) }
  #     }
  #   end
  #
  # The lambda must return a Hash (nil and non-Hash returns are ignored).
  # Base keys (id, session_id) always take precedence and cannot be
  # overridden by the lambda. Exceptions raised by the lambda are not
  # caught — they will propagate to surface misconfiguration immediately.
  #
  # @example
  #   class ApplicationController < ActionController::Base
  #     include StandardId::WebAuthentication
  #     include StandardId::SentryContext
  #   end
  module SentryContext
    extend ActiveSupport::Concern

    included do
      before_action :set_standard_id_sentry_context
    end

    private

    def set_standard_id_sentry_context
      return unless defined?(Sentry)
      return unless respond_to?(:current_account, true) && current_account.present?

      session_value = current_session.presence if respond_to?(:current_session, true)

      base = { id: current_account.id }
      base[:session_id] = session_value.id if session_value&.respond_to?(:id)

      extra = StandardId.config.sentry_context
      if extra.respond_to?(:call)
        result = extra.call(current_account, session_value)
        # Merge lambda result underneath base keys so id/session_id cannot
        # be accidentally overridden by the host app's lambda.
        base = result.merge(base) if result.is_a?(Hash)
      end

      Sentry.set_user(base)
    end
  end
end
