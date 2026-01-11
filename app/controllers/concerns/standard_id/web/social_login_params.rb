module StandardId
  module Web
    module SocialLoginParams
      extend ActiveSupport::Concern

      OAUTH_PENDING_REQUESTS_COOKIE = "oauth_pending_requests".freeze
      REQUEST_EXPIRY = 10.minutes

      private

      def store_oauth_request(state:, nonce: nil, params:)
        pending_requests = load_pending_requests || {}

        cleanup_expired_requests!(pending_requests)

        pending_requests[state] = {
          "params" => params,
          "nonce" => nonce,
          "expires_at" => REQUEST_EXPIRY.from_now.to_i
        }

        save_pending_requests(pending_requests)
      end

      def consume_oauth_request(state)
        return nil if state.blank?

        pending_requests = load_pending_requests
        return nil if pending_requests.nil?

        cleanup_expired_requests!(pending_requests)

        request_data = pending_requests[state]
        return nil if request_data.nil?

        # Remove this specific request from pending requests
        pending_requests.delete(state)

        # Update the cookie with remaining requests
        if pending_requests.empty?
          cookies.delete(OAUTH_PENDING_REQUESTS_COOKIE)
        else
          save_pending_requests(pending_requests)
        end

        request_data.slice("params", "nonce")
      rescue JSON::ParserError
        nil
      end

      def load_pending_requests
        cookie_value = cookies.encrypted[OAUTH_PENDING_REQUESTS_COOKIE]
        return nil if cookie_value.nil?

        JSON.parse(cookie_value)
      rescue JSON::ParserError
        nil
      end

      def save_pending_requests(pending_requests)
        cookie_options = {
          value: pending_requests.to_json,
          expires: REQUEST_EXPIRY.from_now,
          httponly: true
        }

        if request.ssl?
          cookie_options[:secure] = true
          cookie_options[:same_site] = :none
        else
          cookie_options[:same_site] = :lax
        end

        cookies.encrypted[OAUTH_PENDING_REQUESTS_COOKIE] = cookie_options
      end

      def cleanup_expired_requests!(pending_requests)
        current_time = Time.now.to_i
        pending_requests.delete_if { |_state, data| data["expires_at"] && data["expires_at"] < current_time }
      end
    end
  end
end
