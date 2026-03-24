module StandardId
  module RateLimitHandling
    extend ActiveSupport::Concern

    RATE_LIMIT_STORE = StandardId::RateLimitStore.new

    included do
      rescue_from ActionController::TooManyRequests, with: :handle_rate_limited
    end

    private

    def handle_rate_limited(_exception)
      if self.class.ancestors.include?(ActionController::API)
        render json: {
          error: "rate_limit_exceeded",
          error_description: "Too many requests. Please try again later."
        }, status: :too_many_requests
      else
        flash.now[:alert] = "Too many requests. Please try again later."
        head :too_many_requests
      end
    end
  end
end
