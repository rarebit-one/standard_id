class AddPartialIndexesForActiveSessionAndChallengeLookups < ActiveRecord::Migration[8.0]
  # Run indexes CONCURRENTLY on Postgres so we don't take a long write lock on
  # busy tables. SQLite (dummy app, some host setups) ignores algorithm:; we
  # only pass :concurrently when the adapter is Postgres.
  #
  # StrongMigrations note: every change here is additive and non-destructive
  # except for the GIN drop in step 3. We guard that drop with an `if_exists`
  # check so StrongMigrations/host apps that never ran the creating migration
  # (e.g. SQLite dummies) don't error. StrongMigrations considers partial-
  # index-add and remove_index safe when concurrently + if_exists are used, so
  # no ignore comment is needed.
  #
  # Split into def up / def down because `remove_index :table, name: "..."`
  # (name-only, no column list) is not auto-reversible via def change — Rails
  # raises ActiveRecord::IrreversibleMigration on rollback. The explicit down
  # path re-adds the GIN index using the same column + opclass the creating
  # migration used (t.index :metadata, using: :gin).
  disable_ddl_transaction!

  def up
    pg = connection.adapter_name.downcase.include?("postgres")
    concurrent = pg ? { algorithm: :concurrently } : {}

    # ── D3: Partial indexes on hot "active session" lookups ────────────────
    # The existing [:expires_at, :revoked_at] indexes include revoked rows.
    # Most of our hot paths (SessionManager#find_active, cleanup jobs, the
    # revocation controller) only care about revoked_at IS NULL rows, and a
    # partial index on expires_at WHERE revoked_at IS NULL is both smaller
    # and lets Postgres short-circuit the revoked_at check in the plan.
    add_index :standard_id_sessions,
      :expires_at,
      where: "revoked_at IS NULL",
      name: "index_standard_id_sessions_on_expires_at_where_active",
      if_not_exists: true,
      **concurrent

    add_index :standard_id_refresh_tokens,
      :expires_at,
      where: "revoked_at IS NULL",
      name: "index_standard_id_refresh_tokens_on_expires_at_where_active",
      if_not_exists: true,
      **concurrent

    # ── D4: code_challenges index rework ───────────────────────────────────
    # The hot-path consumer is Passwordless::VerificationService#find_active_challenge:
    #
    #   CodeChallenge.active
    #     .where(realm:, channel:, target:)
    #     .order(created_at: :desc).first
    #
    # where `active` = used_at IS NULL AND expires_at > NOW(). We can't put
    # `expires_at > NOW()` into a partial index predicate (NOW() isn't
    # immutable), but `used_at IS NULL` is safe and eliminates consumed OTPs.
    #
    # The existing [:realm, :channel, :target, :created_at] index works but
    # covers every row, including long-since-consumed ones. A partial variant
    # stays tiny (only live challenges) and matches the exact query shape.
    add_index :standard_id_code_challenges,
      [:realm, :channel, :target, :created_at],
      where: "used_at IS NULL",
      name: "index_code_challenges_on_active_target_created_at",
      if_not_exists: true,
      **concurrent

    # Drop the GIN metadata index on Postgres: metadata is only written to
    # (record_failed_attempt bumps `attempts`), never queried with containment
    # (@>, ?, ?|, ?&) operators, so the GIN index is pure write overhead.
    # SQLite never had a GIN index to drop.
    if pg
      remove_index :standard_id_code_challenges,
        name: "index_standard_id_code_challenges_on_metadata",
        if_exists: true,
        **concurrent
    end

    # ── D5: skipped intentionally ──────────────────────────────────────────
    # standard_id_credentials already has a composite
    # (credentialable_type, credentialable_id) index via `t.references
    # :credentialable, polymorphic: true, index: true`. A search of the
    # codebase shows no queries filtering by credentialable_id alone (callers
    # always know the credentialable_type because Credential uses
    # delegated_type). Adding a single-column credentialable_id index would
    # only add write overhead with no matching read pattern, so we skip it.
  end

  def down
    pg = connection.adapter_name.downcase.include?("postgres")
    concurrent = pg ? { algorithm: :concurrently } : {}

    # Re-create the GIN metadata index first (mirrors the creating migration:
    # `t.index :metadata, using: :gin` on standard_id_code_challenges).
    # SQLite never had a GIN index, so this is Postgres-only.
    if pg
      add_index :standard_id_code_challenges,
        :metadata,
        using: :gin,
        name: "index_standard_id_code_challenges_on_metadata",
        if_not_exists: true,
        **concurrent
    end

    remove_index :standard_id_code_challenges,
      name: "index_code_challenges_on_active_target_created_at",
      if_exists: true,
      **concurrent

    remove_index :standard_id_refresh_tokens,
      name: "index_standard_id_refresh_tokens_on_expires_at_where_active",
      if_exists: true,
      **concurrent

    remove_index :standard_id_sessions,
      name: "index_standard_id_sessions_on_expires_at_where_active",
      if_exists: true,
      **concurrent
  end
end
