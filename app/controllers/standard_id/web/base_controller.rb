module StandardId
  module Web
    class BaseController < ApplicationController
      include StandardId::ControllerPolicy
      include StandardId::WebAuthentication
      include StandardId::SetCurrentRequestDetails
      include StandardId::WebMechanismGate
      include StandardId::RateLimitHandling

      include StandardId::WebEngine.routes.url_helpers
      helper StandardId::WebEngine.routes.url_helpers

      layout -> { StandardId.config.web_layout.presence || "application" }

      before_action -> { Current.scope = :web if defined?(::Current) }
      before_action :require_browser_session!

      private

      # Read a top-level query/form param expected to be a scalar String, returning
      # nil for absent/blank values OR if Rails parsed it as an Array/Hash (e.g. from
      # `?redirect_uri[]=a&redirect_uri[]=b`). Without this guard, `redirect_to` is
      # called with a non-String and raises ArgumentError → 500 for any caller that
      # sends a malformed redirect_uri.
      def string_param(key)
        value = params[key]
        value.is_a?(String) ? value.presence : nil
      end
    end
  end
end
