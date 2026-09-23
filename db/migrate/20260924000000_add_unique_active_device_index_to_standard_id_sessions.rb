class AddUniqueActiveDeviceIndexToStandardIdSessions < ActiveRecord::Migration[8.0]
  # One ACTIVE DeviceSession per (account, device).
  #
  # `OauthSessionPersistence.upsert_device_session!` keys OAuth-issued device
  # sessions on a stable device_id and reuses the active row for repeat
  # sign-ins. Until now nothing in the schema backed that: the upsert
  # serialised on a row lock, a race or an older gem could still leave two
  # active rows for one device, and the lookup then picked one arbitrarily.
  # This partial unique index makes "one active row per device" a database
  # invariant; the upsert inserts inside a savepoint and, on
  # RecordNotUnique, reuses the row that won.
  #
  # Partial on purpose:
  #   - `revoked_at IS NULL` — revoked rows are history (audit trail, admin
  #     session list) and a device legitimately accumulates one per sign-out.
  #   - `device_id IS NOT NULL` — BrowserSession / ServiceSession rows share
  #     the table and carry no device_id.
  #
  # Existing duplicates are resolved BEFORE the index is built, without
  # revoking anything: in each duplicated (account_id, device_id) group the
  # newest active row keeps its device_id and every other row has
  # ":detached:<id>" appended to its own. Detached rows stay active — their
  # refresh tokens keep working until they expire or are revoked — they are
  # simply no longer the row a new sign-in on that device reuses. Not undone
  # by `down`: the original device_id is recoverable by stripping the suffix.
  #
  # Idempotent (if_not_exists / if_exists), CONCURRENTLY on Postgres, same
  # conventions as 20260416180511. StrongMigrations treats a concurrent
  # add_index as safe, so no safety_assured is needed.
  disable_ddl_transaction!

  INDEX_NAME = "index_standard_id_sessions_on_active_account_device".freeze
  WHERE = "revoked_at IS NULL AND device_id IS NOT NULL".freeze
  DETACHED_MARKER = ":detached:".freeze

  def up
    pg = connection.adapter_name.downcase.include?("postgres")
    concurrent = pg ? { algorithm: :concurrently } : {}

    # A CONCURRENTLY build that failed (e.g. a duplicate inserted mid-build)
    # leaves an INVALID index behind, which if_not_exists would then skip.
    # Drop it so a re-run actually rebuilds.
    if pg && invalid_postgres_index?(INDEX_NAME)
      remove_index :standard_id_sessions, name: INDEX_NAME, if_exists: true, **concurrent
    end

    detach_duplicate_active_device_sessions!

    add_index :standard_id_sessions,
      [:account_id, :device_id],
      unique: true,
      where: WHERE,
      name: INDEX_NAME,
      if_not_exists: true,
      **concurrent
  end

  def down
    pg = connection.adapter_name.downcase.include?("postgres")
    concurrent = pg ? { algorithm: :concurrently } : {}

    remove_index :standard_id_sessions, name: INDEX_NAME, if_exists: true, **concurrent
  end

  private

  def detach_duplicate_active_device_sessions!
    rows = select_all(<<~SQL.squish).to_a
      SELECT s.id, s.account_id, s.device_id
      FROM standard_id_sessions s
      INNER JOIN (
        SELECT account_id, device_id
        FROM standard_id_sessions
        WHERE #{WHERE}
        GROUP BY account_id, device_id
        HAVING COUNT(*) > 1
      ) dup ON dup.account_id = s.account_id AND dup.device_id = s.device_id
      WHERE s.revoked_at IS NULL AND s.device_id IS NOT NULL
      ORDER BY s.account_id, s.device_id, s.created_at DESC, s.id DESC
    SQL

    rows.group_by { |row| [row["account_id"], row["device_id"]] }.each_value do |group|
      # group.first is the newest active row: it keeps the device_id.
      group.drop(1).each do |row|
        detached = "#{row["device_id"]}#{DETACHED_MARKER}#{row["id"]}"
        execute(<<~SQL.squish)
          UPDATE standard_id_sessions
          SET device_id = #{connection.quote(detached)}
          WHERE id = #{connection.quote(row["id"])}
        SQL
      end
    end
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
