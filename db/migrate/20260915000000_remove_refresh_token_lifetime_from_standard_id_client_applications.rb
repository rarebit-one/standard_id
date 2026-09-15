class RemoveRefreshTokenLifetimeFromStandardIdClientApplications < ActiveRecord::Migration[7.1]
  # Drops the per-client `refresh_token_lifetime` column. It was never honoured:
  # `TokenLifetimeResolver.refresh_token_lifetime` resolves the refresh-token
  # lifetime GLOBALLY from `oauth.refresh_token_lifetime` and has no per-client
  # branch, so the column advertised a knob that did nothing (the #765
  # asymmetry). Refresh-token lifetime is a global policy by design — a client's
  # session cadence is governed by revocation, not by a per-client lifetime
  # (see CHANGELOG, "Revocation is the property the estate wants") — so the
  # column is removed rather than wired up.
  #
  # Access- and authorization-code lifetimes remain per-client.
  def up
    return unless column_exists?(:standard_id_client_applications, :refresh_token_lifetime)

    remove_column :standard_id_client_applications, :refresh_token_lifetime
  end

  def down
    return if column_exists?(:standard_id_client_applications, :refresh_token_lifetime)

    add_column :standard_id_client_applications, :refresh_token_lifetime, :integer, default: 2592000
  end
end
