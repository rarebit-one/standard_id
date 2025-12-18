require_relative "events/definitions"
require_relative "events/event"

module StandardId
  module Events
    # Event namespace prefix for all StandardId events
    NAMESPACE = "standard_id"

    class << self
      # Publish an event with the given name and payload
      #
      # @param event_name [String, Symbol] The event name (use constants from Definitions)
      # @param payload [Hash] The event payload data
      # @yield [Hash] Optional block that receives the payload, useful for lazy evaluation
      # @return [void]
      #
      # @example Simple publish
      #   StandardId::Events.publish(:authentication_succeeded, account: user)
      #
      # @example With block for lazy payload
      #   StandardId::Events.publish(:authentication_succeeded) do
      #     { account: expensive_lookup, duration_ms: calculate_duration }
      #   end
      #
      def publish(event_name, payload = {}, &block)
        event_payload = block ? block.call.merge(payload) : payload
        full_event_name = namespaced_event_name(event_name)

        # Add standard metadata to all events
        enriched_payload = enrich_payload(event_payload, event_name)

        ActiveSupport::Notifications.instrument(full_event_name, enriched_payload)
      rescue ActiveSupport::Notifications::InstrumentationSubscriberError => e
        # Re-raise the first exception only (stop at first failure)
        # This prevents confusing "multiple exceptions" messages when
        # multiple guards (e.g., AccountStatus + AccountLocking) both fail
        raise e.exceptions.first if e.exceptions.any?
      end

      # Subscribe to an event with a block or callable
      #
      # @param event_names [String, Symbol, Array<String, Symbol>] The event name(s) to subscribe to
      # @yield [StandardId::Events::Event] The event object with name, payload, and timing
      # @return [ActiveSupport::Notifications::Fanout::Subscribers::Evented, Array] The subscription(s)
      #
      # @example Block subscription
      #   StandardId::Events.subscribe(:authentication_succeeded) do |event|
      #     puts "Login from #{event.payload[:ip_address]}"
      #   end
      #
      # @example Multiple events subscription
      #   StandardId::Events.subscribe(:session_creating, :session_validating) do |event|
      #     check_account_status(event)
      #   end
      #
      # @example Pattern subscription (subscribe to all authentication events)
      #   StandardId::Events.subscribe(/authentication/) do |event|
      #     audit_log(event)
      #   end
      #
      def subscribe(*event_names, &block)
        event_names = event_names.flatten

        if event_names.size == 1
          subscribe_single(event_names.first, &block)
        else
          event_names.map { |event_name| subscribe_single(event_name, &block) }
        end
      end

      # Subscribe to an event pattern using a regex
      #
      # @param pattern [Regexp] The pattern to match event names
      # @yield [StandardId::Events::Event] The event object
      # @return [ActiveSupport::Notifications::Fanout::Subscribers::Evented] The subscription
      #
      def subscribe_to_pattern(pattern, &block)
        subscribe_single(pattern, &block)
      end

      # Unsubscribe from events
      #
      # @param subscribers [Object, Array<Object>] The subscriber(s) returned from subscribe()
      # @return [void]
      #
      def unsubscribe(*subscribers)
        subscribers.flatten.each do |subscriber|
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
      end

      # Get the full namespaced event name
      #
      # @param event_name [String, Symbol] The short event name
      # @return [String] The full namespaced event name
      #
      def namespaced_event_name(event_name)
        return event_name.to_s if event_name.to_s.start_with?("#{NAMESPACE}.")

        "#{NAMESPACE}.#{event_name}"
      end

      private

      def subscribe_single(event_name, &block)
        pattern = event_name.is_a?(Regexp) ? event_name : namespaced_event_name(event_name)

        ActiveSupport::Notifications.subscribe(pattern) do |name, start, finish, id, payload|
          event = Event.new(
            name: name,
            payload: payload,
            started_at: start,
            finished_at: finish,
            transaction_id: id
          )
          block.call(event)
        end
      end

      def enrich_payload(payload, event_name)
        enriched = {
          event_type: event_name.to_s,
          event_id: SecureRandom.uuid,
          timestamp: Time.current.iso8601
        }

        if defined?(::Current) && ::Current.respond_to?(:request_id)
          enriched[:request_id] = ::Current.request_id if ::Current.request_id.present?
          enriched[:ip_address] ||= ::Current.ip_address if ::Current.respond_to?(:ip_address) && ::Current.ip_address.present?
          enriched[:user_agent] ||= ::Current.user_agent if ::Current.respond_to?(:user_agent) && ::Current.user_agent.present?
        end

        enriched.merge(payload)
      end
    end
  end
end
