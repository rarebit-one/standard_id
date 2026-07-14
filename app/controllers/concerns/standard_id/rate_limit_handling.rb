module StandardId
  module RateLimitHandling
    extend ActiveSupport::Concern

    RATE_LIMIT_STORE = StandardId::RateLimitStore.new

    # Fallback window for the Retry-After header when the tripped limit's window
    # was not captured on the instance — e.g. a hand-rolled `raise
    # TooManyRequests` that bypasses the rate_limit macro (see
    # Api::Oauth::TokensController's per-audience limit, which uses a 15-minute
    # window). Matches that hand-rolled limit's window, so the fallback stays
    # accurate for it.
    DEFAULT_RETRY_AFTER = 15.minutes

    included do
      rescue_from ActionController::TooManyRequests, with: :handle_rate_limited
    end

    class_methods do
      # Wrap Rails' `rate_limit` so the tripped limit's window (`within:`) is
      # remembered on the controller instance, letting the shared
      # `handle_rate_limited` rescue emit a Retry-After that reflects the ACTUAL
      # window instead of a hardcoded 15 minutes (which was 4x wrong for every
      # 1-hour limit — verification/password-reset/signup/api-passwordless start,
      # dynamic registration). This transparently upgrades every existing
      # `rate_limit ... within: X` call site with no change to the call itself.
      #
      # ActionController::TooManyRequests carries no window, and a controller may
      # declare several limits with different windows, so a single class-level
      # value can't identify which limit fired. Capturing it in the per-limit
      # `with:` closure (evaluated in controller context the instant that
      # specific limit trips) is the least-invasive way to thread the correct
      # window through. A host that passes its own `with:` opts out and keeps the
      # default fallback.
      def rate_limit(within:, with: nil, **options)
        with ||= -> {
          @standard_id_rate_limit_within = within
          raise ActionController::TooManyRequests
        }
        super(within: within, with: with, **options)
      end
    end

    # Resolve the effective per-IP login rate limit, preferring the
    # mechanism-agnostic `login_per_ip` alias and falling back to the deprecated
    # `password_login_per_ip` when the host left the alias at its default (i.e.
    # only configured the old name). The new alias wins whenever explicitly set.
    # Mirrors the max_attempts -> max_attempts_per_challenge deprecation-alias
    # precedent (prefer-new, fall-back-to-old).
    def self.login_per_ip
      resolve_login_alias(:login_per_ip, :password_login_per_ip)
    end

    # Effective per-email login rate limit; see .login_per_ip.
    def self.login_per_email
      resolve_login_alias(:login_per_email, :password_login_per_email)
    end

    # Return the alias value unless it still equals its schema default, in which
    # case fall back to the deprecated field. Both fields share the same default,
    # so the effective default is unchanged when neither is set.
    def self.resolve_login_alias(new_field, old_field)
      rate_limits = StandardId.config.rate_limits
      default = StandardId.config.__schema__.field_for(:rate_limits, new_field).default_value
      new_value = rate_limits[new_field]
      new_value == default ? rate_limits[old_field] : new_value
    end

    private

    def handle_rate_limited(_exception)
      retry_after = (@standard_id_rate_limit_within || DEFAULT_RETRY_AFTER).to_i
      response.set_header("Retry-After", retry_after.to_s)

      if self.class.ancestors.include?(ActionController::API)
        render json: {
          error: "rate_limit_exceeded",
          error_description: "Too many requests. Please try again later."
        }, status: :too_many_requests
      elsif request.get? || request.head?
        # A rate-limited GET/HEAD has no sibling form to bounce to. Redirecting
        # to `request.path` (the non-GET branch below) would target the SAME
        # throttled action, so the browser follows the redirect, re-increments
        # the counter, and gets redirected again — an unbounded loop that also
        # keeps resetting the window. v0.28.0 shipped the first rate-limited GETs
        # (email/phone confirm #show), which exposed this. Render a terminal 429
        # instead: the response is the end of the exchange, so it cannot loop.
        render plain: "Too many requests. Please try again later.",
               status: :too_many_requests
      else
        flash[:alert] = "Too many requests. Please try again later."
        # Bounce back to the rate-limited form's own GET action. Previously this
        # used `request.referer || main_app.root_path`, which raised (→ 500) for
        # two real cases: a host app that doesn't define a root route (e.g. an
        # API/control-plane that only mounts the engine — `main_app.root_path`
        # then doesn't exist), and a cross-origin `Referer` (Rails refuses the
        # redirect as unsafe). `request.path` is always a valid, same-origin GET
        # for every rate-limited *non-GET* action here, so it degrades
        # gracefully. (GET/HEAD are handled above to avoid a redirect loop.)
        redirect_to request.path, status: :see_other
      end
    end
  end
end
