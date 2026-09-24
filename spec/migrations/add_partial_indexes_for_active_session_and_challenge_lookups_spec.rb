require "rails_helper"
require_relative "../../db/migrate/20260416180511_add_partial_indexes_for_active_session_and_challenge_lookups"

RSpec.describe AddPartialIndexesForActiveSessionAndChallengeLookups do
  let(:index_name) { "index_code_challenges_on_active_target_created_at" }

  def run(migration, direction)
    ActiveRecord::Migration.suppress_messages { migration.migrate(direction) }
  end

  # SQLite DDL is transactional, so the per-example transaction restores the
  # schema.rb indexes after each example.
  it "asserts the 4-column code_challenges index safe for hosts running StrongMigrations" do
    # StrongMigrations rejects non-unique indexes over more than three columns;
    # every known host runs it. Stand in for its `safety_assured` and check the
    # index is built inside it.
    run(described_class.new, :down)
    migration = described_class.new
    asserted = 0
    migration.define_singleton_method(:safety_assured) { |&blk| asserted += 1; blk.call }

    run(migration, :up)

    expect(asserted).to eq(1)
    expect(ActiveRecord::Base.connection.index_name_exists?(:standard_id_code_challenges, index_name)).to be_truthy
  end

  it "builds the index without StrongMigrations loaded" do
    run(described_class.new, :down)
    run(described_class.new, :up)

    expect(ActiveRecord::Base.connection.index_name_exists?(:standard_id_code_challenges, index_name)).to be_truthy
  end
end
