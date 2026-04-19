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
      ::Current.ip_address = StandardId::Utils::IpNormalizer.normalize(request.remote_ip) if ::Current.respond_to?(:ip_address=)
      ::Current.user_agent = request.user_agent if ::Current.respond_to?(:user_agent=)

      set_rails_event_context
    end

    # Mirror request details into the Rails 8.1+ structured event reporter so
    # that `Rails.event.notify` calls made during this request automatically
    # carry request_id / ip_address / user_agent. Feature-detected: on older
    # Rails versions this is a no-op.
    def set_rails_event_context
      return unless Rails.respond_to?(:event) && Rails.event.respond_to?(:set_context)

      Rails.event.set_context(
        request_id: ::Current.respond_to?(:request_id) ? ::Current.request_id : nil,
        ip_address: ::Current.respond_to?(:ip_address) ? ::Current.ip_address : nil,
        user_agent: ::Current.respond_to?(:user_agent) ? ::Current.user_agent : nil
      )
    end
  end
end
