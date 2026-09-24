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

    # state: :not_installed — no host migration file with this name
    #        :not_run       — the host file exists but its version is not in schema_migrations
    Missing = Data.define(:name, :version, :state) do
      def to_s = "#{version}_#{name} (#{state.to_s.tr('_', ' ')})"
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

      gem_migrations.filter_map do |version, name|
        next if ignore.include?(name) || ignore.include?(version)

        host_versions = host[name]
        if host_versions.blank?
          Missing.new(name: name, version: version, state: :not_installed)
        elsif applied && (host_versions & applied).empty?
          Missing.new(name: name, version: version, state: :not_run)
        end
      end
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

      missing = pending
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
