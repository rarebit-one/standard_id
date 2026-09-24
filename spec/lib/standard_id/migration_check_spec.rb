require "rails_helper"
require "tmpdir"

RSpec.describe StandardId::MigrationCheck do
  let(:gem_migrations) { described_class.gem_migrations }
  let(:tmp_root) { File.expand_path("../../../tmp", __dir__).tap { |d| FileUtils.mkdir_p(d) } }

  around do |example|
    Dir.mktmpdir("standard_id_migrations", tmp_root) do |dir|
      @host_dir = dir
      example.run
    end
  end

  # Mimic `standard_id:install:migrations`: new timestamps, `.standard_id` suffix.
  def install(migrations = gem_migrations, suffix: ".standard_id")
    migrations.each_with_index do |(_version, name), i|
      FileUtils.touch(File.join(@host_dir, "#{20300101000000 + i}_#{name}#{suffix}.rb"))
    end
  end

  def pending(**kwargs)
    described_class.pending(paths: [@host_dir], ignore: [], **kwargs)
  end

  it "knows every migration the gem ships" do
    expect(gem_migrations.map(&:last)).to include("add_partial_indexes_for_active_session_and_challenge_lookups")
    expect(gem_migrations.size).to eq(Dir[File.join(described_class::GEM_MIGRATIONS_PATH, "*.rb")].size)
  end

  it "reports nothing when every migration was installed (re-timestamped)" do
    install
    expect(pending).to be_empty
  end

  it "matches copies without the .standard_id suffix" do
    install(suffix: "")
    expect(pending).to be_empty
  end

  it "reports a migration that was never copied, by its original version" do
    skipped = gem_migrations.find { |_v, name| name == "add_partial_indexes_for_active_session_and_challenge_lookups" }
    install(gem_migrations - [skipped])

    expect(pending).to eq([
      described_class::Missing.new(name: skipped.last, version: "20260416180511", state: :not_installed)
    ])
    expect(pending.first.to_s).to eq("20260416180511_add_partial_indexes_for_active_session_and_challenge_lookups (not installed)")
  end

  it "skips ignored migrations by name or by original version" do
    install(gem_migrations.first(gem_migrations.size - 2))
    last_two = gem_migrations.last(2)

    expect(described_class.pending(paths: [@host_dir], ignore: [last_two[0].last, last_two[1].first])).to be_empty
  end

  it "reads config.ignored_migrations by default" do
    install(gem_migrations.first(gem_migrations.size - 1))
    allow(StandardId.config).to receive(:ignored_migrations).and_return([gem_migrations.last.last])

    expect(described_class.pending(paths: [@host_dir])).to be_empty
  end

  describe "check_database: true" do
    it "reports installed migrations whose host version was never run" do
      install
      host_versions = Dir.children(@host_dir).map { |f| f[/\A\d+/] }.sort
      allow(described_class).to receive(:applied_versions).and_return(host_versions[0..-2])

      result = pending(check_database: true)
      expect(result.map(&:state)).to eq([:not_run])
      expect(result.first.name).to eq(gem_migrations.last.last)
    end

    it "does not touch the database otherwise" do
      install
      expect(described_class).not_to receive(:applied_versions)
      pending
    end
  end

  describe ".mode" do
    it "defaults to :warn in development/test" do
      allow(StandardId.config).to receive(:missing_migrations).and_return(nil)
      expect(described_class.mode).to eq(:warn)
    end

    it "defaults to :ignore in production" do
      allow(StandardId.config).to receive(:missing_migrations).and_return(nil)
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      expect(described_class.mode).to eq(:ignore)
    end

    it "honours the configured value" do
      allow(StandardId.config).to receive(:missing_migrations).and_return(:raise)
      expect(described_class.mode).to eq(:raise)
    end
  end

  describe ".verify_at_boot!" do
    let(:missing) { [described_class::Missing.new(name: "x", version: "1", state: :not_installed)] }

    before { allow(described_class).to receive(:pending).and_return(missing) }

    it "raises in :raise mode" do
      allow(StandardId.config).to receive(:missing_migrations).and_return(:raise)
      expect { described_class.verify_at_boot! }.to raise_error(StandardId::ConfigurationError, /standard_id:install:migrations/)
    end

    it "logs in :warn mode" do
      allow(StandardId.config).to receive(:missing_migrations).and_return(:warn)
      expect(Rails.logger).to receive(:warn).with(/1 StandardId migration\(s\) are not installed/)
      expect { described_class.verify_at_boot! }.to output(/1_x \(not installed\)/).to_stderr
    end

    it "does nothing in :ignore mode" do
      allow(StandardId.config).to receive(:missing_migrations).and_return(:ignore)
      expect(described_class).not_to receive(:pending)
      described_class.verify_at_boot!
    end

    it "does nothing when nothing is missing" do
      allow(StandardId.config).to receive(:missing_migrations).and_return(:raise)
      allow(described_class).to receive(:pending).and_return([])
      expect { described_class.verify_at_boot! }.not_to raise_error
    end

    it "rejects an unknown mode" do
      allow(StandardId.config).to receive(:missing_migrations).and_return(:loud)
      expect { described_class.verify_at_boot! }.to raise_error(StandardId::ConfigurationError, /missing_migrations/)
    end
  end
end

RSpec.describe StandardId::Checks::Migrations do
  subject(:check) { described_class.new }

  after { described_class.all_present = false }

  it "is non-critical by default and named for the health JSON" do
    expect(check.critical?).to be(false)
    expect(check.name).to eq(:standard_id_migrations)
  end

  it "warns (never fails) when migrations are missing, listing them" do
    missing = StandardId::MigrationCheck::Missing.new(name: "x", version: "1", state: :not_run)
    allow(StandardId::MigrationCheck).to receive(:pending).with(check_database: true).and_return([missing])

    result = check.run
    expect(result[:status]).to eq(:warn)
    expect(result[:message]).to include("1_x (not run)")
    expect(result[:missing]).to eq([{ name: "x", version: "1", state: :not_run }])
  end

  it "memoizes :ok once everything is present" do
    expect(StandardId::MigrationCheck).to receive(:pending).once.and_return([])

    expect(check.run).to eq(status: :ok)
    expect(described_class.new.run).to eq(status: :ok)
  end

  it "reports :fail instead of raising" do
    allow(StandardId::MigrationCheck).to receive(:pending).and_raise(ActiveRecord::ConnectionNotEstablished, "down")

    expect(check.run).to include(status: :fail, error_class: "ActiveRecord::ConnectionNotEstablished")
  end
end
