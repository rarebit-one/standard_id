class AddValueLookupIndexesToStandardIdTables < ActiveRecord::Migration[8.0]
  # Indexes for two lookups nothing in the schema serves (deep audit
  # DBP-002/DBP-011, 2026-10-27):
  #
  # - standard_id_identifiers [type, value]: every sign-in, OTP start, social
  #   login and password reset resolves its identifier with
  #   `EmailIdentifier.find_by(value:)` / `PhoneNumberIdentifier.find_by(value:)`
  #   (STI adds `type = ?`). The only index containing `value` leads with
  #   account_id, so each lookup is a sequential scan. Not unique: the same
  #   value may belong to more than one account.
  # - standard_id_refresh_tokens client_application_id: PurgeStaleDynamicClientsJob
  #   reads refresh tokens per client (`client.refresh_tokens`) and by
  #   `client_application_id IS NOT NULL`. Partial, because tokens not bound
  #   to an application (social sign-in refreshes, rows minted before
  #   20261020000000) leave it NULL.
  #
  # At today's table sizes these scans are cheap (Sentry, 14 days: the
  # identifier lookup is p50 2-4ms, p95 9-15ms in every host); the cost grows
  # with every account. Idempotent (if_not_exists / if_exists), CONCURRENTLY
  # on Postgres, and an INVALID index left by a failed concurrent build is
  # dropped and rebuilt, same conventions as 20260924000000.
  disable_ddl_transaction!

  INDEXES = [
    {
      table: :standard_id_identifiers,
      columns: [:type, :value],
      name: "index_standard_id_identifiers_on_type_and_value"
    },
    {
      table: :standard_id_refresh_tokens,
      columns: :client_application_id,
      name: "index_standard_id_refresh_tokens_on_client_application_id",
      where: "client_application_id IS NOT NULL"
    }
  ].freeze

  def up
    INDEXES.each do |index|
      if postgres? && invalid_postgres_index?(index[:name])
        remove_index index[:table], name: index[:name], if_exists: true, **concurrent
      end

      add_index index[:table], index[:columns],
        name: index[:name], where: index[:where], if_not_exists: true, **concurrent
    end
  end

  def down
    INDEXES.each do |index|
      remove_index index[:table], name: index[:name], if_exists: true, **concurrent
    end
  end

  private

  def postgres?
    connection.adapter_name.downcase.include?("postgres")
  end

  def concurrent
    postgres? ? { algorithm: :concurrently } : {}
  end

  def invalid_postgres_index?(name)
    select_value(<<~SQL.squish).present?
      SELECT 1
      FROM pg_index i
      INNER JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = #{connection.quote(name)} AND NOT i.indisvalid
    SQL
  end
end
