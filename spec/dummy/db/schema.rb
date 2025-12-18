# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_12_13_000000) do
  create_table "accounts", force: :cascade do |t|
    t.string "email", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status", default: "active", null: false
    t.datetime "activated_at"
    t.datetime "deactivated_at"
    t.boolean "locked", default: false, null: false
    t.datetime "locked_at"
    t.string "lock_reason"
    t.integer "locked_by_id"
    t.string "locked_by_type"
    t.datetime "unlocked_at"
    t.integer "unlocked_by_id"
    t.string "unlocked_by_type"
    t.index ["email"], name: "index_accounts_on_email", unique: true
    t.index ["locked"], name: "index_accounts_on_locked"
  end

  create_table "standard_id_audit_logs", force: :cascade do |t|
    t.string "event_type", null: false
    t.string "request_id"
    t.string "actor_type"
    t.bigint "actor_id"
    t.string "target_type"
    t.bigint "target_id"
    t.string "ip_address"
    t.datetime "occurred_at", null: false
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_type", "actor_id"], name: "index_standard_id_audit_logs_on_actor"
    t.index ["event_type"], name: "index_standard_id_audit_logs_on_event_type"
    t.index ["ip_address"], name: "index_standard_id_audit_logs_on_ip_address"
    t.index ["occurred_at"], name: "index_standard_id_audit_logs_on_occurred_at", order: :desc
    t.index ["request_id"], name: "index_standard_id_audit_logs_on_request_id"
    t.index ["target_type", "target_id"], name: "index_standard_id_audit_logs_on_target"
  end

  create_table "standard_id_authorization_codes", force: :cascade do |t|
    t.bigint "account_id"
    t.string "code_hash", null: false
    t.string "client_id", null: false
    t.text "redirect_uri", null: false
    t.string "scope"
    t.string "audience"
    t.string "nonce"
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.datetime "issued_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "expires_at"], name: "idx_on_account_id_expires_at_22bee5ab05"
    t.index ["account_id"], name: "index_standard_id_authorization_codes_on_account_id"
    t.index ["client_id", "expires_at"], name: "idx_on_client_id_expires_at_413231188c"
    t.index ["code_hash"], name: "index_standard_id_authorization_codes_on_code_hash", unique: true
    t.index ["consumed_at"], name: "index_standard_id_authorization_codes_on_consumed_at"
    t.index ["expires_at"], name: "index_standard_id_authorization_codes_on_expires_at"
  end

  create_table "standard_id_client_applications", force: :cascade do |t|
    t.string "owner_type", null: false
    t.integer "owner_id", null: false
    t.string "name", null: false
    t.text "description"
    t.string "client_id", null: false
    t.text "redirect_uris", null: false
    t.string "scopes", default: "openid profile email"
    t.string "grant_types", default: "authorization_code refresh_token"
    t.string "response_types", default: "code"
    t.boolean "require_pkce", default: true, null: false
    t.string "code_challenge_methods", default: "S256"
    t.integer "access_token_lifetime", default: 3600
    t.integer "refresh_token_lifetime", default: 2592000
    t.integer "authorization_code_lifetime", default: 600
    t.string "client_type", default: "confidential", null: false
    t.boolean "require_consent", default: true, null: false
    t.boolean "active", default: true, null: false
    t.datetime "deactivated_at"
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_standard_id_client_applications_on_active"
    t.index ["client_id"], name: "index_standard_id_client_applications_on_client_id", unique: true
    t.index ["client_type"], name: "index_standard_id_client_applications_on_client_type"
    t.index ["owner_type", "owner_id"], name: "idx_on_owner_type_owner_id_936e856298"
    t.index ["owner_type", "owner_id"], name: "index_standard_id_client_applications_on_owner"
  end

  create_table "standard_id_client_secret_credentials", force: :cascade do |t|
    t.string "name", null: false
    t.integer "client_application_id", null: false
    t.string "client_id", null: false
    t.string "client_secret_digest", null: false
    t.string "scopes"
    t.string "redirect_uris"
    t.boolean "active", default: true, null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["client_application_id"], name: "idx_on_client_application_id_2d812bdcd6"
    t.index ["client_id"], name: "index_standard_id_client_secret_credentials_on_client_id"
  end

  create_table "standard_id_code_challenges", force: :cascade do |t|
    t.string "realm", null: false
    t.string "channel", null: false
    t.string "target", null: false
    t.string "code", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.string "ip_address"
    t.text "user_agent"
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_standard_id_code_challenges_on_expires_at"
    t.index ["realm", "channel", "target", "code"], name: "index_code_challenges_on_lookup"
    t.index ["used_at"], name: "index_standard_id_code_challenges_on_used_at"
  end

  create_table "standard_id_credentials", force: :cascade do |t|
    t.integer "identifier_id", null: false
    t.string "credentialable_type", null: false
    t.integer "credentialable_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["credentialable_type", "credentialable_id"], name: "index_standard_id_credentials_on_credentialable"
    t.index ["identifier_id"], name: "index_standard_id_credentials_on_identifier_id"
  end

  create_table "standard_id_identifiers", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "type", null: false
    t.string "value", null: false
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "type", "value"], name: "index_standard_id_identifiers_on_account_id_and_type_and_value", unique: true
    t.index ["account_id"], name: "index_standard_id_identifiers_on_account_id"
  end

  create_table "standard_id_password_credentials", force: :cascade do |t|
    t.string "login", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["login"], name: "index_standard_id_password_credentials_on_login", unique: true
  end

  create_table "standard_id_sessions", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "type", null: false
    t.string "lookup_hash", null: false
    t.string "token_digest", null: false
    t.string "ip_address"
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.json "metadata", default: {}, null: false
    t.text "user_agent"
    t.string "device_id"
    t.text "device_agent"
    t.datetime "last_refreshed_at"
    t.string "owner_type"
    t.integer "owner_id"
    t.string "service_name"
    t.string "service_version"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "type", "expires_at"], name: "idx_on_account_id_type_expires_at_fed5f68be5"
    t.index ["account_id"], name: "index_standard_id_sessions_on_account_id"
    t.index ["expires_at", "revoked_at"], name: "index_standard_id_sessions_on_expires_at_and_revoked_at"
    t.index ["lookup_hash", "expires_at", "revoked_at"], name: "idx_on_lookup_hash_expires_at_revoked_at_34a4504c19"
    t.index ["lookup_hash"], name: "index_standard_id_sessions_on_lookup_hash", unique: true
    t.index ["owner_type", "owner_id"], name: "index_standard_id_sessions_on_owner"
    t.index ["type"], name: "index_standard_id_sessions_on_type"
  end

  add_foreign_key "standard_id_authorization_codes", "accounts"
  add_foreign_key "standard_id_client_secret_credentials", "standard_id_client_applications", column: "client_application_id"
  add_foreign_key "standard_id_credentials", "standard_id_identifiers", column: "identifier_id"
  add_foreign_key "standard_id_identifiers", "accounts"
  add_foreign_key "standard_id_sessions", "accounts"
end
