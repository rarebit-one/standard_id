module StandardId
  module SetCurrentRequestDetails
    extend ActiveSupport::Concern

    included do
      before_action :set_current_request_details
    end

    private

    def set_current_request_details
      return unless defined?(::Current)

      ::Current.request_id = request.request_id if ::Current.respond_to?(:request_id=)
      ::Current.ip_address = request.remote_ip if ::Current.respond_to?(:ip_address=)
      ::Current.user_agent = request.user_agent if ::Current.respond_to?(:user_agent=)
    end
  end
end
