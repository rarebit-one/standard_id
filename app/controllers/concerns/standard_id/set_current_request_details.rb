module StandardId
  module SetCurrentRequestDetails
    extend ActiveSupport::Concern

    included do
      before_action :set_current_request_details
      after_action  :clear_rails_event_context
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
    # Rails versions this is a no-op. Reads straight from `::Current` — setters
    # and getters on `ActiveSupport::CurrentAttributes` are paired, so the
    # `respond_to?(:foo=)` checks above also guarantee the getter exists.
    def set_rails_event_context
      return unless defined?(::Current) && rails_event_available?

      Rails.event.set_context(
        request_id: (::Current.request_id if ::Current.respond_to?(:request_id)),
        ip_address: (::Current.ip_address if ::Current.respond_to?(:ip_address)),
        user_agent: (::Current.user_agent if ::Current.respond_to?(:user_agent))
      )
    end

    # Rails 8.1 clears fiber-local state between requests via middleware, but
    # thread-pooled servers (Puma, Falcon) can reuse the same fiber across
    # requests. An explicit clear ensures a denied-upstream value cannot leak
    # into the next request handled by the same worker.
    def clear_rails_event_context
      return unless rails_event_available?

      Rails.event.clear_context
    end

    def rails_event_available?
      Rails.respond_to?(:event) && Rails.event.respond_to?(:set_context)
    end
  end
end
