module StandardId
  module Events
    module Subscribers
      # Base class for event subscribers
      #
      # @example Single event subscription
      #   class AuditSubscriber < StandardId::Events::Subscribers::Base
      #     subscribe_to StandardId::Events::AUTHENTICATION_SUCCEEDED
      #
      #     def call(event)
      #       AuditLog.create!(
      #         event_type: event.short_name,
      #         account_id: event[:account]&.id,
      #         ip_address: event[:ip_address],
      #         metadata: event.payload
      #       )
      #     end
      #   end
      #
      # @example Multiple event subscription
      #   class SecurityAlertSubscriber < StandardId::Events::Subscribers::Base
      #     subscribe_to StandardId::Events::AUTHENTICATION_FAILED,
      #                  StandardId::Events::SESSION_REVOKED,
      #                  StandardId::Events::ACCOUNT_LOCKED
      #
      #     def call(event)
      #       SecurityMailer.alert(event.to_h).deliver_later
      #     end
      #   end
      #
      # @example Pattern subscription
      #   class MetricsSubscriber < StandardId::Events::Subscribers::Base
      #     subscribe_to_pattern(/authentication/)
      #
      #     def call(event)
      #       StatsD.increment("standard_id.#{event.short_name}")
      #     end
      #   end
      #
      class Base
        class << self
          # Subscribe to specific event(s)
          #
          # @param event_names [Array<String>] Event name constants
          # @return [void]
          #
          def subscribe_to(*event_names)
            @subscribed_events = event_names.flatten
          end

          # Subscribe to events matching a pattern
          #
          # @param pattern [Regexp] Pattern to match event names
          # @return [void]
          #
          def subscribe_to_pattern(pattern)
            @subscription_pattern = pattern
          end

          # Get the subscribed events
          #
          # @return [Array<String>]
          #
          def subscribed_events
            @subscribed_events || []
          end

          # Get the subscription pattern
          #
          # @return [Regexp, nil]
          #
          def subscription_pattern
            @subscription_pattern
          end

          # Register this subscriber with the event system
          #
          # @return [Array<Object>] The subscription handles
          #
          def attach
            instance = new
            @subscriptions ||= []

            if subscription_pattern
              @subscriptions << Events.subscribe(subscription_pattern) do |event|
                instance.handle(event)
              end
            end

            subscribed_events.each do |event_name|
              @subscriptions << Events.subscribe(event_name) do |event|
                instance.handle(event)
              end
            end

            @subscriptions
          end

          # Unregister this subscriber from the event system
          #
          # @return [void]
          #
          def detach
            return unless @subscriptions

            @subscriptions.each do |subscription|
              Events.unsubscribe(subscription)
            end
            @subscriptions = []
          end

          # Check if the subscriber is currently attached
          #
          # @return [Boolean]
          #
          def attached?
            @subscriptions&.any?
          end
        end

        # Handle an event
        #
        # Override this method to add custom handling logic like
        # async processing or error handling. By default, it calls
        # the `call` method.
        #
        # @param event [StandardId::Events::Event] The event to handle
        # @return [void]
        #
        def handle(event)
          call(event)
        rescue StandardError => e
          handle_error(e, event)
        end

        # Process the event
        #
        # Subclasses must implement this method.
        #
        # @param event [StandardId::Events::Event] The event to process
        # @raise [NotImplementedError] If not implemented by subclass
        #
        def call(event)
          raise NotImplementedError, "#{self.class.name} must implement #call"
        end

        # Handle errors during event processing
        #
        # Override this method to customize error handling.
        # By default, it logs the error and re-raises.
        #
        # @param error [StandardError] The error that occurred
        # @param event [StandardId::Events::Event] The event being processed
        # @raise [StandardError] Re-raises the error by default
        #
        def handle_error(error, event)
          StandardId.logger.error(
            "[StandardId::Events] Error in #{self.class.name} handling #{event.short_name}: #{error.message}"
          )
          raise error
        end
      end
    end
  end
end
