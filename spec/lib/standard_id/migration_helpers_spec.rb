require "rails_helper"
require "tmpdir"

RSpec.describe StandardId::MigrationHelpers do
  let(:tmp_root) { File.expand_path("../../../tmp", __dir__).tap { |d| FileUtils.mkdir_p(d) } }

  # Define a migration class from a file with the given basename, the way
  # the migrator `load`s a host's db/migrate file.
  def load_migration(basename, class_name, body = "")
    Dir.mktmpdir("standard_id_migration_helpers", tmp_root) do |dir|
      path = File.join(dir, basename)
      File.write(path, <<~RUBY)
        class #{class_name} < ActiveRecord::Migration[8.0]
          #{body}
        end
      RUBY
      load path
    end
    Object.const_get(class_name)
  end

  after do
    %i[HostOwnMigrationForSpec LegacyStandardIdCopyForSpec UnsuffixedStandardIdCopyForSpec].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const, false)
    end
  end

  it "no longer adds the helpers to every migration" do
    migration = load_migration("20300101000000_create_widgets.rb", "HostOwnMigrationForSpec")

    expect(migration.new).not_to respond_to(:primary_key_type)
    expect(migration).not_to respond_to(:foreign_key_type)
    expect(ActiveRecord::Migration.instance_methods).not_to include(:primary_key_type)
  end

  it "keeps host copies installed before the explicit include working" do
    migration = load_migration("20300101000001_create_standard_id_sessions.standard_id.rb", "LegacyStandardIdCopyForSpec")

    expect(migration.new.primary_key_type).to eq(:bigint)
    expect(migration.foreign_key_type).to eq(:bigint)
  end

  it "recognises copies without the .standard_id suffix" do
    migration = load_migration("20300101000002_create_standard_id_identifiers.rb", "UnsuffixedStandardIdCopyForSpec")

    expect(migration.new.foreign_key_type).to eq(:bigint)
  end

  it "follows the host's generator primary_key_type" do
    migration = load_migration("20300101000001_create_standard_id_sessions.standard_id.rb", "LegacyStandardIdCopyForSpec")
    generators = Rails.configuration.generators
    allow(generators).to receive(:options).and_return(generators.options.deep_merge(generators.orm => { primary_key_type: :uuid }))

    expect(migration.new.primary_key_type).to eq(:uuid)
  end

  it "is included explicitly by every gem migration that uses the helpers" do
    Dir[File.join(StandardId::MigrationCheck::GEM_MIGRATIONS_PATH, "*.rb")].each do |file|
      source = File.read(file)
      next unless source.match?(/\b(primary|foreign)_key_type\b/)

      expect(source).to include("include StandardId::MigrationHelpers"), "#{File.basename(file)} uses the helpers without including them"
    end
  end
end
