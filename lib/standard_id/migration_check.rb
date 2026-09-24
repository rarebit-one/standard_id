module StandardId
  # Detects StandardId migrations a host never installed (or installed but
  # never ran).
  #
  # WHY
  #
  # `bin/rails standard_id:install:migrations` copies the engine's migrations
  # into the host with NEW timestamps. Rails' pending-migration check only
  # sees files that are in the host's db/migrate, so a gem migration that was
  # never copied is invisible to it — fundbright-web, luminality-web and
  # nutripod-web each ran for months without 20260416180511's indexes, and
  # two still lack 20260414200000. This compares by migration NAME (the part
  # after the timestamp, with or without the `.standard_id` suffix Rails adds),
  # which survives the re-timestamping.
  #
  # COST
  #
  # A Dir.glob over the host's migration paths; the database is only consulted
  # (one `schema_migrations` read) when `check_database: true`, which the boot
  # check never passes.
  module MigrationCheck
    GEM_MIGRATIONS_PATH = File.expand_path("../../db/migrate", __dir__)
    FILENAME = /\A(\d+)_(\w+?)(?:\.[a-z_]+)?\.rb\z/

    # A gem migration whose job is fully done by a LATER gem migration, so a
    # host that installed the later one may skip it. name => superseding name.
    #
    # 20260414200000 adds a plain, non-concurrent 4-column index on
    # standard_id_code_challenges; 20260416180511 adds the partial
    # `index_code_challenges_on_active_target_created_at` (same columns,
    # WHERE used_at IS NULL, built CONCURRENTLY) that serves the same lookups.
    # Hosts on busy tables (fundbright-web, luminality-web) skipped the former
    # on purpose rather than take the write lock.
    SUPERSEDED_BY = {
      "add_target_created_at_index_to_code_challenges" =>
        "add_partial_indexes_for_active_session_and_challenge_lookups"
    }.freeze

    # Gem migrations hosts are EXPECTED to hold back for a while — reported as
    # a pending upgrade step (severity :info), never as an error, so they do
    # not warn at boot, fail boot in :raise mode, or degrade the health check.
    #
    # 20260915000000 drops a column 0.41.1 ignores; per the 0.41.1 upgrade
    # notes it must only run once 0.41.1+ is deployed everywhere.
    DEFERRED_UPGRADE_STEPS = {
      "remove_refresh_token_lifetime_from_standard_id_client_applications" =>
        "run once StandardId >= 0.41.1 is deployed to every process (it drops a column 0.41.1 ignores)"
    }.freeze

    # state:    :not_installed — no host migration file with this name
    #           :not_run       — the host file exists but its version is not in schema_migrations
    # severity: :error — a migration the host should have
    #           :info  — a DEFERRED_UPGRADE_STEPS entry: pending, but intentionally
    Missing = Data.define(:name, :version, :state, :severity) do
      def initialize(name:, version:, state:, severity: :error) = super

      def info? = severity == :info

      def to_s
        label = state.to_s.tr("_", " ")
        info? ? "#{version}_#{name} (#{label}; pending upgrade step: #{DEFERRED_UPGRADE_STEPS[name]})" : "#{version}_#{name} (#{label})"
      end
    end

    MODES = %i[warn raise ignore].freeze

    module_function

    # @return [Array<Array(String, String)>] [[original_version, name], ...] for every gem migration
    def gem_migrations
      @gem_migrations ||= parse_dir(GEM_MIGRATIONS_PATH).sort.freeze
    end

    # @param paths [Array<String>] host migration directories
    # @param check_database [Boolean] also report installed-but-unrun migrations
    # @param ignore [Array<String>] migration names (or original versions) to skip
    # @return [Array<Missing>]
    def pending(paths: host_migration_paths, check_database: false, ignore: StandardId.config.ignored_migrations)
      ignore = Array(ignore).map(&:to_s)
      host = host_versions_by_name(paths)
      applied = check_database ? applied_versions : nil

      present = ->(migration_name) { present_in_host?(host[migration_name], applied) }

      gem_migrations.filter_map do |version, name|
        next if ignore.include?(name) || ignore.include?(version)

        host_versions = host[name]
        state = if host_versions.blank?
                  :not_installed
        elsif applied && (host_versions & applied).empty?
                  :not_run
        end
        next if state.nil?
        next if (successor = SUPERSEDED_BY[name]) && present.call(successor)

        severity = DEFERRED_UPGRADE_STEPS.key?(name) ? :info : :error
        Missing.new(name: name, version: version, state: state, severity: severity)
      end
    end

    # Installed (and, when +applied+ is given, run).
    def present_in_host?(host_versions, applied)
      return false if host_versions.blank?

      applied.nil? || (host_versions & applied).any?
    end

    # The mode in effect: config.missing_migrations, else :warn in
    # development/test and :ignore everywhere else (never raise in production
    # by default).
    def mode
      configured = StandardId.config.missing_migrations
      return configured.to_sym if configured.present?

      Rails.env.local? ? :warn : :ignore
    end

    # Called from the engine's after_initialize. File-system only — boot must
    # not need a database (assets:precompile, db:create).
    #
    # @raise [StandardId::ConfigurationError] in :raise mode when migrations are missing
    def verify_at_boot!
      current = mode
      unless MODES.include?(current)
        raise StandardId::ConfigurationError,
          "StandardId.config.missing_migrations must be one of #{MODES.inspect} (got #{current.inspect})"
      end
      return if current == :ignore

      all_missing = pending
      deferred, missing = all_missing.partition(&:info?)
      Rails.logger.info(deferred_message(deferred)) if deferred.any?
      return if missing.empty?

      message = boot_message(missing)
      raise StandardId::ConfigurationError, message if current == :raise

      Rails.logger.warn(message)
      warn(message) if Rails.env.local?
    end

    def boot_message(missing)
      <<~MESSAGE.strip
        [StandardId] #{missing.size} StandardId migration(s) are not installed in this app:
          #{missing.map(&:to_s).join("\n  ")}
        Run `bin/rails standard_id:install:migrations && bin/rails db:migrate`.
        If one is deliberately skipped (e.g. superseded by a host migration), list its name in
        `StandardId.config.ignored_migrations`. Set `config.missing_migrations = :raise` to fail
        boot instead, or `:ignore` to silence this check.
      MESSAGE
    end

    def deferred_message(deferred)
      "[StandardId] Pending upgrade step(s), held back intentionally: #{deferred.map(&:to_s).join('; ')}"
    end

    def host_migration_paths
      paths = Rails.application.paths["db/migrate"].existent
      paths += Array(ActiveRecord::Migrator.migrations_paths).map { |p| File.expand_path(p, Rails.root) }
      paths.uniq.select { |p| File.directory?(p) }
    end

    def host_versions_by_name(paths)
      Array(paths).flat_map { |dir| parse_dir(dir) }.each_with_object({}) do |(version, name), acc|
        (acc[name] ||= []) << version
      end
    end

    def parse_dir(dir)
      Dir.children(dir).filter_map do |file|
        match = FILENAME.match(file)
        [match[1], match[2]] if match
      end
    rescue Errno::ENOENT
      []
    end

    def applied_versions
      ActiveRecord::Base.connection_pool.schema_migration.versions
    end
  end
end
