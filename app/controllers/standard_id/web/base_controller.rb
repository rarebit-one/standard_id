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
      helper StandardId::ApplicationHelper

      layout -> { StandardId.config.web_layout.presence || "application" }

      before_action -> { Current.scope = :web if defined?(::Current) }
      before_action :require_browser_session!

      # The authentication guard (require_browser_session!) RAISES when a page
      # requires a session that's missing / expired / revoked, rather than
      # redirecting. The API base controller rescues the same errors; the web
      # flow must too, or an unauthenticated request to a protected page (e.g.
      # /sessions) surfaces as a 500 instead of bouncing to login. Expired and
      # revoked sessions are InvalidSessionError subclasses.
      rescue_from StandardId::NotAuthenticatedError,
                  StandardId::InvalidSessionError,
                  with: :redirect_unauthenticated_to_login

      private

      # Bounce an unauthenticated web request to the login page, preserving the
      # original destination (the guard already stored return_to_after_authenticating;
      # redirect_to_login also carries it as a ?redirect_uri= param).
      def redirect_unauthenticated_to_login(_error)
        store_location_for_redirect
        redirect_to_login
      end

      # Prefix an engine-relative path with the current mount point's SCRIPT_NAME.
      #
      # Isolated-engine `_path` helpers return paths relative to the engine mount
      # (e.g. "/login_verify"), and `redirect_to` / `redirect_with_inertia` —
      # unlike view URL generation (form_with / link_to / url_for) — do NOT
      # prepend the mount's SCRIPT_NAME. So a bare `redirect_to login_verify_path`
      # 404s when the engine is mounted at a non-root path (e.g. "/auth" yields
      # "/login_verify" instead of "/auth/login_verify"). SCRIPT_NAME is "" for a
      # root mount, so this is a no-op there. Apply ONLY to engine-relative paths
      # — host destinations (after_authentication_url, safe_post_signin_default)
      # are already absolute and must not be prefixed.
      def engine_path(path)
        "#{request.script_name}#{path}"
      end

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
      # - Same-origin absolute URLs ("https://this-host/...") pass — `store_location_for_redirect`
      #   stashes `request.url` in session, so callers wrapping `after_authentication_url`
      #   need same-origin URLs accepted.
      # - Cross-host URLs pass only when the host has explicitly allow-listed the prefix
      #   via `StandardId.config.allowed_redirect_url_prefixes`.
      # - Anything else (blank, absolute URL not in the allow-list, protocol-relative,
      #   opaque scheme) is rejected; callers should fall back to `safe_post_signin_default`.
      def safe_destination?(destination)
        return false if destination.blank?
        return true if destination.start_with?("/") && !destination.start_with?("//")
        return true if same_origin_url?(destination)

        allow_listed_redirect?(destination)
      end

      # Whether the host has explicitly allow-listed `destination`'s prefix via
      # `StandardId.config.allowed_redirect_url_prefixes`. This is the only way a
      # cross-origin or custom-scheme destination (e.g. "myapp://done") clears
      # `safe_destination?`, so it is also exactly the condition under which
      # `redirect_to` needs `allow_other_host: true` — Rails otherwise raises
      # UnsafeRedirectError. Mirrors the pattern already used by the social
      # callback (Web::Auth::Callback::ProvidersController).
      def allow_listed_redirect?(destination)
        return false if destination.blank?

        Array(StandardId.config.allowed_redirect_url_prefixes).any? do |entry|
          case entry
          when Regexp then entry.match?(destination)
          else destination.start_with?(entry.to_s)
          end
        end
      end

      # Redirect a just-authenticated account to an already-validated `destination`.
      #
      # Uses `redirect_with_inertia` rather than `redirect_to` because the sign-in
      # submit itself may be an Inertia XHR (hosts with `use_inertia` render the
      # WebEngine's auth pages as Inertia components) while `destination` may not be
      # an Inertia endpoint at all — the canonical case being the ApiEngine's
      # /api/authorize in an OAuth flow. An Inertia client follows a 303 with its
      # X-Inertia header still attached; inertia_rails' middleware then calls
      # #inertia_configuration on the target controller, which ActionController::API
      # controllers never receive (inertia_rails only includes its Controller module
      # via `on_load(:action_controller_base)`), raising NoMethodError → 500.
      # Emitting 409 + X-Inertia-Location instead makes the client do a full page
      # visit, which drops the header. The destination being same-origin is not
      # enough to make a plain redirect safe, so this deliberately keys off the
      # request being Inertia rather than off the destination.
      #
      # `notice` is written to `flash` instead of being passed as a redirect option
      # because `inertia_location` ignores redirect options — writing it to the
      # session is what lets the message survive on both branches.
      def redirect_after_authentication(destination, notice: nil, status: :see_other)
        flash[:notice] = notice if notice.present?

        options = { status: status }
        options[:allow_other_host] = true if allow_listed_redirect?(destination)

        redirect_with_inertia destination, **options
      end

      def same_origin_url?(destination)
        return false unless destination.start_with?("http://", "https://")
        URI.parse(destination).origin == URI.parse(request.base_url).origin
      rescue URI::Error, ArgumentError
        false
      end

      def safe_post_signin_default
        "/"
      end
    end
  end
end
