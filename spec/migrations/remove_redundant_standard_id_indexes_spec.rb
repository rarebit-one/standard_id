require "rails_helper"
require_relative "../../db/migrate/20261028100000_remove_redundant_standard_id_indexes"

RSpec.describe RemoveRedundantStandardIdIndexes do
  # Runs these examples outside the transaction on the PostgreSQL CI leg
  # (CONCURRENTLY cannot run inside one). Guarded until #446 adds it.
  include MigrationSpecSupport if defined?(MigrationSpecSupport)

  let(:connection) { ActiveRecord::Base.connection }
  let(:postgres) { connection.adapter_name.downcase.include?("postgres") }
  let(:dropped) do
    described_class::INDEXES.reject { |index| index[:postgres_only] && !postgres }
  end

  def run(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  def index_named(table, name)
    connection.indexes(table).find { |i| i.name == name }
  end

  # SQLite DDL is transactional, so the per-example transaction restores the
  # schema.rb indexes after each example.
  before { run(:down) }

  it "drops each redundant or unused index" do
    expect(dropped).to all(satisfy { |index| index_named(index[:table], index[:name]) })

    run(:up)

    dropped.each do |index|
      expect(index_named(index[:table], index[:name])).to be_nil, "#{index[:name]} still exists"
    end
  end

  it "keeps the index that covers each dropped one" do
    run(:up)

    covering = {
      standard_id_sessions: [%w[account_id type expires_at], %w[lookup_hash]],
      standard_id_refresh_tokens: [%w[account_id revoked_at], %w[session_id revoked_at]],
      standard_id_authorization_codes: [%w[account_id expires_at]],
      standard_id_client_grants: [%w[account_id client_id]],
      standard_id_identifiers: [%w[account_id type value]],
      standard_id_client_applications: [%w[owner_type owner_id]]
    }
    covering.each do |table, column_sets|
      column_sets.each do |columns|
        expect(connection.indexes(table).map(&:columns)).to include(columns), "#{table} lost #{columns}"
      end
    end
    expect(index_named(:standard_id_client_applications, "index_standard_id_client_applications_on_owner")).to be_present
  end

  it "is idempotent and reversible" do
    run(:up)
    expect { run(:up) }.not_to raise_error

    run(:down)
    dropped.each do |index|
      expect(index_named(index[:table], index[:name])).to be_present, "#{index[:name]} not restored"
    end
    expect { run(:down) }.not_to raise_error
  end
end
