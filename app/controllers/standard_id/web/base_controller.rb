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

      # Whether `destination` is safe to redirect a signed-in user to.
      # - Same-origin paths ("/foo") pass; protocol-relative ("//evil") does not.
      # - Cross-host URLs pass only when the host has explicitly allow-listed the prefix
      #   via `StandardId.config.allowed_redirect_url_prefixes`.
      # - Anything else (blank, absolute http(s) URL not in the allow-list, opaque scheme)
      #   is rejected; callers should fall back to `safe_post_signin_default`.
      def safe_destination?(destination)
        return false if destination.blank?
        return true if destination.start_with?("/") && !destination.start_with?("//")

        Array(StandardId.config.allowed_redirect_url_prefixes).any? do |entry|
          case entry
          when Regexp then entry.match?(destination)
          else destination.start_with?(entry.to_s)
          end
        end
      end

      def safe_post_signin_default
        "/"
      end
    end
  end
end
