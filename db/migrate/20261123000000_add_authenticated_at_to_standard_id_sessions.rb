# When a session (and the refresh tokens derived from it) last proved the
# account's identity: set at sign-in and on a step-up, never by remember-me or
# a refresh. Read by `require_recent_authentication!` (StandardId::StepUp).
#
# Two nullable datetime columns with no default and no index, so both are
# metadata-only on PostgreSQL. NULL reads as "not recently", which is what
# every session and refresh token created before this migration is: the guard
# asks those users to step up once. Until this has run, the gem writes neither
# column and the guard raises StandardId::ConfigurationError naming it.
class AddAuthenticatedAtToStandardIdSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :standard_id_sessions, :authenticated_at, :datetime
    add_column :standard_id_refresh_tokens, :authenticated_at, :datetime
  end
end
