# Records which flow created an identifier's sign-up. EmailPassword::Registration
# writes "email_password"; nothing else writes it, so NULL means any other
# sign-up (Web::SignupForm, social, passwordless, the host's own). The email +
# password API reads it to tell its own pending sign-ups apart: a password
# reset runs `after_email_verified` only for them, and
# PurgeUnverifiedEmailSignupsJob only ever deletes them. One nullable string
# column, no default, no index: metadata-only on PostgreSQL. Required before
# enabling `c.email_password`.
class AddSignupSourceToStandardIdIdentifiers < ActiveRecord::Migration[8.0]
  def change
    add_column :standard_id_identifiers, :signup_source, :string
  end
end
