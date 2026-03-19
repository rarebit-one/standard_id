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
    field :account_scope, type: :any, default: nil
    field :use_inertia, type: :boolean, default: false
    field :inertia_component_namespace, type: :string, default: "standard_id"
    field :alias_current_user, type: :boolean, default: false
    # Callable (lambda/proc) that returns a Hash of extra Sentry user context fields.
    # Receives (account, session) where session may be nil. Non-callable values are ignored.
    field :sentry_context, type: :any, default: nil
  end

  scope :events do
    field :enable_logging, type: :boolean, default: false
  end

  scope :passwordless do
    field :enabled, type: :boolean, default: false
    field :connection, type: :string, default: "email"
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

  scope :session do
    field :browser_session_lifetime, type: :integer, default: 86400 # 24 hours in seconds
    field :browser_session_remember_me_lifetime, type: :integer, default: 2592000 # 30 days in seconds
    field :device_session_lifetime, type: :integer, default: 2592000 # 30 days in seconds
    field :service_session_lifetime, type: :integer, default: 7776000 # 90 days in seconds
  end

  scope :oauth do
    field :default_token_lifetime, type: :integer, default: 3600 # 1 hour in seconds
    field :refresh_token_lifetime, type: :integer, default: 2592000 # 30 days in seconds
    field :token_lifetimes, type: :hash, default: -> { {} }
    field :client_id, type: :string, default: nil
    field :client_secret, type: :string, default: nil
    field :scope_claims, type: :hash, default: -> { {} }
    field :claim_resolvers, type: :hash, default: -> { {} }
    field :allowed_audiences, type: :array, default: -> { [] } # Empty = no validation, any audience allowed

    # JWT signing configuration (for asymmetric algorithms)
    # If nil, uses HS256 with Rails.application.secret_key_base
    field :signing_key, type: :any, default: nil

    # Previous signing keys for key rotation (array of PEM strings or Pathnames)
    # During rotation, move the old signing_key here so tokens signed with it
    # can still be verified. Remove after the grace period.
    field :previous_signing_keys, type: :array, default: -> { [] }

    # Signing algorithm (see JwtService::SUPPORTED_ALGORITHMS for full list)
    # Symmetric (HMAC): :hs256, :hs384, :hs512
    # Asymmetric (RSA): :rs256, :rs384, :rs512
    # Asymmetric (ECDSA): :es256, :es384, :es512
    field :signing_algorithm, type: :symbol, default: :hs256
  end

  scope :social do
    field :social_account_attributes, type: :any, default: nil
    field :allowed_redirect_url_prefixes, type: :array, default: []
    field :available_scopes, type: :array, default: -> { [] }
  end
end
