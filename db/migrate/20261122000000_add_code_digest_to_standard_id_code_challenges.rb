# Passwordless / OTP codes were stored in plaintext in `code`, so anyone who
# could read the table could sign in with any active code. From this migration
# on, StandardId stores only `code_digest`, an HMAC-SHA256 of the code keyed on
# secret_key_base (StandardId::CodeChallenge.digest_code), and leaves `code`
# NULL on new rows.
#
# Both steps are metadata-only on PostgreSQL: a nullable string column with no
# default and no index (a challenge is found by realm/channel/target, then its
# digest is compared in constant time), and dropping a NOT NULL constraint.
#
# `code` is kept, nullable, for one transition: challenges issued before the
# deploy still carry a plaintext code and are verified against it until they
# expire (code_ttl, 10 minutes by default) and CleanupExpiredCodeChallengesJob
# deletes them. A later release drops the column; see docs/MIGRATION_GUIDE.md.
# Until this has run, the gem keeps writing the plaintext column as before.
#
# Rolling back restores NOT NULL on `code`, which fails while any digest-only
# row exists: delete those first (they are at most code_ttl old).
class AddCodeDigestToStandardIdCodeChallenges < ActiveRecord::Migration[8.0]
  def change
    add_column :standard_id_code_challenges, :code_digest, :string
    change_column_null :standard_id_code_challenges, :code, true
  end
end
