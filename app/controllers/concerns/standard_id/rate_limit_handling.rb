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
        redirect_to request.referer || main_app.root_path, status: :see_other
      end
    end
  end
end
