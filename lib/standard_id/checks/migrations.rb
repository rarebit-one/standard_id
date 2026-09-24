module StandardId
  module Checks
    # A StandardHealth-compatible readiness check reporting StandardId
    # migrations the host never installed or never ran (see
    # StandardId::MigrationCheck).
    #
    # Duck-typed like StandardAudit::Checks::Retention — no dependency on
    # standard_health; it exposes the `#initialize(name:, critical:)` + `#run`
    # contract the aggregator calls. Register it NON-critical, so a missing
    # index degrades /health/ready (HTTP 200) instead of failing the probe:
    #
    #   c.register_check :standard_id_migrations,
    #                    StandardId::Checks::Migrations,
    #                    critical: false
    #
    # Cheap: one directory scan plus one `schema_migrations` read, and once
    # everything is present the :ok result is memoized for the life of the
    # process (migration files cannot change without a deploy).
    class Migrations
      attr_reader :name

      def initialize(name: :standard_id_migrations, critical: false)
        @name = name
        @critical = critical
      end

      def critical? = !!@critical

      def run
        return { status: :ok } if self.class.all_present?

        missing = StandardId::MigrationCheck.pending(check_database: true)
        if missing.empty?
          self.class.all_present = true
          return { status: :ok }
        end

        {
          status: :warn,
          message: "#{missing.size} StandardId migration(s) missing: #{missing.map(&:to_s).join(', ')}",
          missing: missing.map { |m| { name: m.name, version: m.version, state: m.state } }
        }
      rescue StandardError => e
        { status: :fail, error: e.message, error_class: e.class.name }
      end

      class << self
        attr_writer :all_present

        def all_present? = !!@all_present
      end
    end
  end
end
