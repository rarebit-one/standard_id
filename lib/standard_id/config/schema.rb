# Schema definitions for StandardId
# This file defines the configuration schema structure

require "standard_config"

StandardConfig.schema.draw do
  scope :base do
    field :account_class_name, type: :string, default: "User"
    field :cache_store, type: :any, default: nil
    field :logger, type: :any, default: nil
    field :web_layout, type: :string, default: nil
    field :passwordless_email_sender, type: :any, default: nil
    field :passwordless_sms_sender, type: :any, default: nil
    field :issuer, type: :string, default: nil
    field :login_url, type: :string, default: nil
    field :allowed_post_logout_redirect_uris, type: :array, default: []
  end

  scope :passwordless do
    field :code_ttl, type: :integer, default: 600 # 10 minutes in seconds
    field :max_attempts, type: :integer, default: 3
    field :retry_delay, type: :integer, default: 30 # 30 seconds
  end

  scope :password do
    field :minimum_length, type: :integer, default: 8
    field :require_special_chars, type: :boolean, default: false
    field :require_uppercase, type: :boolean, default: false
    field :require_numbers, type: :boolean, default: false
  end

  scope :oauth do
    field :default_token_lifetime, type: :integer, default: 3600 # 1 hour in seconds
    field :refresh_token_lifetime, type: :integer, default: 2592000 # 30 days in seconds
    field :token_lifetimes, type: :hash, default: -> { {} }
    field :client_id, type: :string, default: nil
    field :client_secret, type: :string, default: nil
    field :scope_claims, type: :hash, default: -> { {} }
    field :claim_resolvers, type: :hash, default: -> { {} }
  end

  scope :social do
    field :google_client_id, type: :string, default: nil
    field :google_client_secret, type: :string, default: nil
    field :apple_client_id, type: :string, default: nil
    field :apple_client_secret, type: :string, default: nil
    field :apple_private_key, type: :string, default: nil
    field :apple_key_id, type: :string, default: nil
    field :apple_team_id, type: :string, default: nil
    field :social_account_attributes, type: :any, default: nil
  end
end
