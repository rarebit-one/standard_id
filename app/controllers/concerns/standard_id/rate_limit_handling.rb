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

    # Effective per-IP login rate limit (`rate_limits.login_per_ip`). The
    # deprecated `password_login_per_ip` fallback was removed in 0.43.
    def self.login_per_ip
      StandardId.config.rate_limits.login_per_ip
    end

    # Effective per-email login rate limit (`rate_limits.login_per_email`).
    def self.login_per_email
      StandardId.config.rate_limits.login_per_email
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
