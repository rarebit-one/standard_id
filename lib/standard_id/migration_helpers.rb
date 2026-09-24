require "active_support/concern"

module StandardId
  # `primary_key_type` / `foreign_key_type` for StandardId's own migrations:
  # the host's generator `primary_key_type` (e.g. :uuid), else :bigint.
  #
  # These used to be monkey-patched onto ActiveRecord::Migration itself, so
  # every migration in every host app gained three methods it never asked for.
  # They are now scoped to StandardId migrations:
  #
  # * the gem's migrations `include StandardId::MigrationHelpers` explicitly
  #   (so newly installed copies carry the include with them), and
  # * copies installed BEFORE that line existed — which call the helpers with
  #   no include — are recognised by file name (a StandardId migration name,
  #   with or without the `.standard_id` suffix) when their class is defined,
  #   and get the module then. No other migration is touched.
  module MigrationHelpers
    extend ActiveSupport::Concern

    class_methods do
      def primary_and_foreign_key_types
        config = Rails.configuration.generators
        config.options[config.orm][:primary_key_type] || :bigint
      end

      def primary_key_type = primary_and_foreign_key_types
      def foreign_key_type = primary_and_foreign_key_types
    end

    def primary_and_foreign_key_types = self.class.primary_and_foreign_key_types
    def primary_key_type = self.class.primary_key_type
    def foreign_key_type = self.class.foreign_key_type

    # Is +path+ a (possibly host-copied) StandardId migration file?
    def self.standard_id_migration_file?(path)
      return false if path.nil?

      match = StandardId::MigrationCheck::FILENAME.match(File.basename(path))
      return false unless match

      gem_migration_names.include?(match[2])
    end

    def self.gem_migration_names
      @gem_migration_names ||= StandardId::MigrationCheck.gem_migrations.to_set(&:last).freeze
    end

    # Prepended onto ActiveRecord::Migration's singleton class. `inherited`
    # fires while the migration's `class ... < ActiveRecord::Migration[x]`
    # line runs, so the caller location is the migration file itself.
    module LegacyCopySupport
      def inherited(subclass)
        super
        path = caller_locations(1, 1).first&.path
        return unless StandardId::MigrationHelpers.standard_id_migration_file?(path)

        subclass.include(StandardId::MigrationHelpers)
      end
    end
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Migration.singleton_class.prepend(StandardId::MigrationHelpers::LegacyCopySupport)
end
