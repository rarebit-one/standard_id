module StandardId
  module Events
    # Event object that wraps ActiveSupport::Notifications event data
    #
    # Provides a clean interface for accessing event information in subscribers.
    #
    # @attr_reader [String] name The full namespaced event name
    # @attr_reader [Hash] payload The event payload data
    # @attr_reader [Time] started_at When the event started
    # @attr_reader [Time] finished_at When the event finished
    # @attr_reader [String] transaction_id Unique identifier for this event instance
    #
    class Event
      attr_reader :name, :payload, :started_at, :finished_at, :transaction_id

      # @param name [String] The full namespaced event name
      # @param payload [Hash] The event payload
      # @param started_at [Time] When the event started
      # @param finished_at [Time] When the event finished
      # @param transaction_id [String] Unique identifier for the event
      def initialize(name:, payload:, started_at: nil, finished_at: nil, transaction_id: nil)
        @name = name
        @payload = payload.with_indifferent_access
        @started_at = started_at
        @finished_at = finished_at
        @transaction_id = transaction_id
      end

      # Get the event name without the namespace prefix
      #
      # @return [String] The short event name
      # @example
      #   event.short_name # => "authentication.attempt.succeeded"
      #
      def short_name
        name.to_s.delete_prefix("#{Events::NAMESPACE}.")
      end

      # Get the event type from the payload
      #
      # @return [String, nil] The event type
      #
      def event_type
        payload[:event_type]
      end

      # Get the unique event ID
      #
      # @return [String, nil] The event UUID
      #
      def event_id
        payload[:event_id]
      end

      # Get the event timestamp
      #
      # @return [String, nil] ISO8601 formatted timestamp
      #
      def timestamp
        payload[:timestamp]
      end

      # Calculate the duration of the event in milliseconds
      #
      # @return [Float, nil] Duration in milliseconds, or nil if timing not available
      #
      def duration_ms
        return nil unless started_at && finished_at
        (finished_at - started_at) * 1000
      end

      # Convenience method to access payload values
      #
      # @param key [Symbol, String] The payload key
      # @return [Object] The value from the payload
      #
      def [](key)
        payload[key]
      end

      # Check if the payload contains a key
      #
      # @param key [Symbol, String] The payload key
      # @return [Boolean]
      #
      def key?(key)
        payload.key?(key)
      end

      # Convert event to a hash representation
      #
      # @return [Hash] The event as a hash
      #
      def to_h
        {
          name: name,
          short_name: short_name,
          transaction_id: transaction_id,
          started_at: started_at&.iso8601,
          finished_at: finished_at&.iso8601,
          duration_ms: duration_ms,
          payload: payload.to_h
        }
      end

      # Convert event to JSON
      #
      # @return [String] JSON representation
      #
      def to_json(*args)
        to_h.to_json(*args)
      end

      # String representation for debugging
      #
      # @return [String]
      #
      def inspect
        "#<#{self.class.name} name=#{name} event_id=#{event_id} duration_ms=#{duration_ms}>"
      end
    end
  end
end
