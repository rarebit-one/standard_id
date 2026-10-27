require "rails_helper"
require_relative "../../db/migrate/20261028000000_add_value_lookup_indexes_to_standard_id_tables"

RSpec.describe AddValueLookupIndexesToStandardIdTables do
  let(:connection) { ActiveRecord::Base.connection }

  def run(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(direction) }
  end

  def index_named(table, name)
    connection.indexes(table).find { |i| i.name == name }
  end

  # SQLite DDL is transactional, so the per-example transaction restores the
  # schema.rb indexes after each example.
  before { run(:down) }

  it "adds a [type, value] index on identifiers for find_by(value:)" do
    run(:up)

    index = index_named(:standard_id_identifiers, "index_standard_id_identifiers_on_type_and_value")
    expect(index).to be_present
    expect(index.columns).to eq(%w[type value])
    expect(index.unique).to be(false)
  end

  it "adds a partial client_application_id index on refresh tokens" do
    run(:up)

    index = index_named(:standard_id_refresh_tokens, "index_standard_id_refresh_tokens_on_client_application_id")
    expect(index).to be_present
    expect(index.columns).to eq(%w[client_application_id])
    expect(index.where).to eq("client_application_id IS NOT NULL")
  end

  it "is idempotent and reversible" do
    run(:up)
    expect { run(:up) }.not_to raise_error

    run(:down)
    expect(index_named(:standard_id_identifiers, "index_standard_id_identifiers_on_type_and_value")).to be_nil
    expect(index_named(:standard_id_refresh_tokens, "index_standard_id_refresh_tokens_on_client_application_id")).to be_nil
  end
end
