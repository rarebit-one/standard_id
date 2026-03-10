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

      context = { id: current_account.id }
      context[:session_id] = current_session.id if respond_to?(:current_session, true) && current_session.present?

      Sentry.set_user(context)
    end
  end
end
