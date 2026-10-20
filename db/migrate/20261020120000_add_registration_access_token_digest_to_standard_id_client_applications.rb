# RFC 7592 client-configuration management for dynamically registered clients.
# The registration access token is returned once, at registration, and only
# its digest is stored; a non-NULL digest is also what marks a client as
# dynamically registered (StandardId::ClientApplication.dynamically_registered),
# which the stale-client purge keys on. One nullable string column, no
# default, no index (lookup is by client_id, then a constant-time compare):
# metadata-only on PostgreSQL. Until it has run, registration works as before
# (no registration_access_token / registration_client_uri in the response) and
# the management endpoints are absent (404).
class AddRegistrationAccessTokenDigestToStandardIdClientApplications < ActiveRecord::Migration[8.0]
  def change
    add_column :standard_id_client_applications, :registration_access_token_digest, :string
  end
end
