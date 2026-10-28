class RemoveRedundantStandardIdIndexes < ActiveRecord::Migration[8.0]
  # Drops indexes the gem's own migrations created that no query needs (deep
  # audit DBP-009, 2026-10-27). Each is write amplification on the tables the
  # auth path writes most: every sign-in inserts a session, every refresh a
  # refresh token.
  #
  # Redundant: another index leads with the same column(s), so every lookup
  # and every foreign-key check it served is served by that one. None of them
  # is unique; no unique index is touched.
  #
  #   sessions [account_id]                     <- [account_id, type, expires_at]
  #   sessions [lookup_hash, expires_at, revoked_at]
  #                                             <- [lookup_hash] UNIQUE
  #   refresh_tokens [account_id]               <- [account_id, revoked_at]
  #   refresh_tokens [session_id]               <- [session_id, revoked_at]
  #   authorization_codes [account_id]          <- [account_id, expires_at]
  #   client_grants [account_id]                <- [account_id, client_id] UNIQUE
  #   identifiers [account_id]                  <- [account_id, type, value] UNIQUE
  #   client_applications [owner_type, owner_id] "idx_on_owner_type_owner_id_..."
  #                                             <- the identical index t.references
  #                                                created ("..._on_owner")
  #
  # Unused (PostgreSQL only; SQLite never had them): the GIN `metadata` indexes
  # on sessions, authorization_codes and client_applications. Nothing in the
  # gem, the provider plugins or the five consumer apps queries those columns
  # with a containment operator (@>, ?, ?|, ?&); the one host query on
  # client_applications.metadata uses `->> =`, which a GIN jsonb_ops index
  # cannot serve. 20260416180511 dropped the code_challenges GIN for the same
  # reason.
  #
  # Every name below was checked against the schema of all five consumer apps
  # (identical everywhere, as is the covering index). Idempotent (if_exists /
  # if_not_exists) and CONCURRENTLY on Postgres, like 20261028000000; `down`
  # rebuilds each one as it was.
  disable_ddl_transaction!

  INDEXES = [
    { table: :standard_id_sessions, columns: :account_id,
      name: "index_standard_id_sessions_on_account_id" },
    { table: :standard_id_sessions, columns: [:lookup_hash, :expires_at, :revoked_at],
      name: "idx_on_lookup_hash_expires_at_revoked_at_34a4504c19" },
    { table: :standard_id_refresh_tokens, columns: :account_id,
      name: "index_standard_id_refresh_tokens_on_account_id" },
    { table: :standard_id_refresh_tokens, columns: :session_id,
      name: "index_standard_id_refresh_tokens_on_session_id" },
    { table: :standard_id_authorization_codes, columns: :account_id,
      name: "index_standard_id_authorization_codes_on_account_id" },
    { table: :standard_id_client_grants, columns: :account_id,
      name: "index_standard_id_client_grants_on_account_id" },
    { table: :standard_id_identifiers, columns: :account_id,
      name: "index_standard_id_identifiers_on_account_id" },
    { table: :standard_id_client_applications, columns: [:owner_type, :owner_id],
      name: "idx_on_owner_type_owner_id_936e856298" },
    { table: :standard_id_sessions, columns: :metadata, using: :gin, postgres_only: true,
      name: "index_standard_id_sessions_on_metadata" },
    { table: :standard_id_authorization_codes, columns: :metadata, using: :gin, postgres_only: true,
      name: "index_standard_id_authorization_codes_on_metadata" },
    { table: :standard_id_client_applications, columns: :metadata, using: :gin, postgres_only: true,
      name: "index_standard_id_client_applications_on_metadata" }
  ].freeze

  def up
    INDEXES.each do |index|
      next if index[:postgres_only] && !postgres?

      remove_index index[:table], name: index[:name], if_exists: true, **concurrent
    end
  end

  def down
    INDEXES.each do |index|
      next if index[:postgres_only] && !postgres?

      options = { name: index[:name], if_not_exists: true, **concurrent }
      options[:using] = index[:using] if index[:using]
      add_index index[:table], index[:columns], **options
    end
  end

  private

  def postgres?
    connection.adapter_name.downcase.include?("postgres")
  end

  def concurrent
    postgres? ? { algorithm: :concurrently } : {}
  end
end
