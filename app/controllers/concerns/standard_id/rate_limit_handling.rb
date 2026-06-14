module StandardId
  module RateLimitHandling
    extend ActiveSupport::Concern

    RATE_LIMIT_STORE = StandardId::RateLimitStore.new

    included do
      rescue_from ActionController::TooManyRequests, with: :handle_rate_limited
    end

    private

    def handle_rate_limited(_exception)
      response.set_header("Retry-After", 15.minutes.to_i.to_s)

      if self.class.ancestors.include?(ActionController::API)
        render json: {
          error: "rate_limit_exceeded",
          error_description: "Too many requests. Please try again later."
        }, status: :too_many_requests
      else
        flash[:alert] = "Too many requests. Please try again later."
        # Bounce back to the rate-limited form's own GET action. Previously this
        # used `request.referer || main_app.root_path`, which raised (→ 500) for
        # two real cases: a host app that doesn't define a root route (e.g. an
        # API/control-plane that only mounts the engine — `main_app.root_path`
        # then doesn't exist), and a cross-origin `Referer` (Rails refuses the
        # redirect as unsafe). `request.path` is always a valid, same-origin GET
        # for every rate-limited action here, so it degrades gracefully.
        redirect_to request.path, status: :see_other
      end
    end
  end
end
