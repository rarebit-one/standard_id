module StandardId
  class Metric < ApplicationRecord
    STATUSES = %w[success failure].freeze

    validates :name, presence: true
    validates :time_bucket, presence: true
    validates :count, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :status, inclusion: { in: STATUSES }

    scope :for_metric, ->(name) { where(name: name) }
    scope :in_time_range, ->(range) { where(time_bucket: range) }
    scope :today, -> { in_time_range(Time.current.beginning_of_day..Time.current.end_of_day) }
    scope :this_hour, -> { in_time_range(Time.current.beginning_of_hour..Time.current.end_of_hour) }
    scope :successful, -> { where(status: "success") }
    scope :failed, -> { where(status: "failure") }

    class << self
      # Increment a metric counter using upsert
      #
      # @param name [String] Metric name (e.g., "auth.attempt")
      # @param status [String, nil] Status ("success" or "failure")
      # @param dimensions [Hash] Additional dimension key-value pairs for grouping
      # @param time_bucket [Time] The time bucket (defaults to current hour)
      # @param increment_by [Integer] Amount to increment (default: 1)
      # @param duration [Float] Duration in milliseconds to add (for averages)
      # @return [void]
      #
      def increment(name:, status: "success", dimensions: {}, time_bucket: nil, increment_by: 1, duration: 0.0)
        bucket = time_bucket || Time.current.beginning_of_hour
        dims = normalize_dimensions(dimensions)

        upsert_metric(name, status, dims, bucket, increment_by, duration)
      end

      # Query total count for a metric
      #
      # @param name [String] Metric name
      # @param time_range [Range] Time range to query
      # @param status [String, nil] Optional status filter
      # @param dimensions [Hash] Optional dimension filters
      # @return [Integer]
      #
      def total_count(name:, time_range:, status: :not_specified, dimensions: {})
        query = for_metric(name).in_time_range(time_range)
        query = query.where(status: status) unless status == :not_specified
        query = apply_dimension_filters(query, dimensions)
        query.sum(:count)
      end

      # Query average duration (total_duration / count)
      #
      # @param name [String] Metric name
      # @param time_range [Range] Time range to query
      # @param status [String, nil] Optional status filter
      # @param dimensions [Hash] Optional dimension filters
      # @return [Float, nil] Average duration in milliseconds
      #
      def average_duration(name:, time_range:, status: :not_specified, dimensions: {})
        query = for_metric(name).in_time_range(time_range)
        query = query.where(status: status) unless status == :not_specified
        query = apply_dimension_filters(query, dimensions)

        total_count = query.sum(:count)
        return nil unless total_count.positive?

        query.sum(:total_duration) / total_count.to_f
      end

      # Calculate success rate for a metric
      #
      # @param name [String] Metric name
      # @param time_range [Range] Time range to query
      # @return [Float, nil] Success rate as percentage (0-100)
      #
      def success_rate(name:, time_range:)
        success_count = total_count(name: name, time_range: time_range, status: "success")
        failure_count = total_count(name: name, time_range: time_range, status: "failure")

        total = success_count + failure_count
        return nil if total.zero?

        (success_count.to_f / total * 100).round(2)
      end

      private

      def normalize_dimensions(dimensions)
        dimensions.transform_keys(&:to_s).sort.to_h
      end

      def apply_dimension_filters(query, dimensions)
        return query if dimensions.empty?

        dimensions.each do |key, value|
          if connection.adapter_name.downcase.include?("postgres")
            query = query.where("dimensions->>? = ?", key.to_s, value.to_s)
          else
            query = query.where("JSON_EXTRACT(dimensions, ?) = ?", "$.#{key}", value.to_s)
          end
        end
        query
      end

      def upsert_metric(name, status, dimensions, bucket, increment_by, duration)
        now = Time.current

        upsert_all(
          [{
            name: name,
            status: status,
            dimensions: dimensions,
            time_bucket: bucket,
            count: increment_by,
            total_duration: duration,
            created_at: now,
            updated_at: now
          }],
          unique_by: :index_metrics_unique_bucket,
          on_duplicate: Arel.sql(
            "count = standard_id_metrics.count + EXCLUDED.count, " \
            "total_duration = standard_id_metrics.total_duration + EXCLUDED.total_duration, " \
            "updated_at = EXCLUDED.updated_at"
          )
        )
      end
    end
  end
end
