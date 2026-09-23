require "rails_helper"

# 0.41.0 dropped `standard_id_client_applications.refresh_token_lifetime`
# without first ignoring it. During a rolling deploy, processes on the previous
# code still had the column in their cached schema and named it in every
# INSERT/UPDATE after the migration removed it. Ignoring the column lets hosts
# deploy this release BEFORE running 20260915000000 — and the model must work
# on both sides of that migration.
RSpec.describe StandardId::ClientApplication, "ignored refresh_token_lifetime column" do
  let(:account) { Account.create!(name: "Owner", email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:connection) { ActiveRecord::Base.connection }

  def create_client!
    described_class.create!(owner: account, name: "Client", redirect_uris: "https://example.com/cb")
  end

  def captured_sql
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  after { described_class.reset_column_information }

  it "is ignored" do
    expect(described_class.ignored_columns).to include("refresh_token_lifetime")
  end

  context "after 20260915000000 has dropped the column" do
    it "creates and updates clients" do
      expect(connection.column_exists?(:standard_id_client_applications, :refresh_token_lifetime)).to be(false)

      client = create_client!
      expect { client.update!(name: "Renamed") }.not_to raise_error
    end
  end

  # The deploy-first window: the column still exists, but this code must not
  # read or write it, so dropping it later cannot break running processes.
  context "before 20260915000000 has run (column still present)" do
    before do
      # SQLite DDL is transactional: the per-example transaction drops it again.
      connection.add_column :standard_id_client_applications, :refresh_token_lifetime, :integer, default: 2_592_000
      described_class.reset_column_information
    end

    it "neither loads nor writes the column" do
      expect(described_class.column_names).not_to include("refresh_token_lifetime")

      sql = captured_sql do
        client = create_client!
        client.update!(name: "Renamed")
        described_class.find(client.id)
      end

      expect(sql.grep(/refresh_token_lifetime/)).to be_empty
    end
  end
end
