module StandardId
  class ClientApplication < ApplicationRecord
    self.table_name = "standard_id_client_applications"
    belongs_to :owner, polymorphic: true

    has_many :client_secret_credentials, dependent: :destroy
    has_many :authorization_codes, foreign_key: :client_id, primary_key: :client_id, dependent: :destroy

    accepts_nested_attributes_for :client_secret_credentials, allow_destroy: false

    # Validations
    validates :name, presence: true, length: { maximum: 255 }
    validates :description, length: { maximum: 1000 }
    validates :redirect_uris, presence: true
    validates :client_type, inclusion: { in: %w[confidential public] }
    validates :grant_types, presence: true
    validates :response_types, presence: true
    validates :scopes, presence: true
    validates :code_challenge_methods, presence: true, if: :require_pkce?

    # Lifecycle validations
    validates :access_token_lifetime, :refresh_token_lifetime, :authorization_code_lifetime,
              presence: true, numericality: { greater_than: 0 }

    # Scopes
    scope :active, -> { where(active: true) }
    scope :confidential, -> { where(client_type: "confidential") }
    scope :public_clients, -> { where(client_type: "public") }
    scope :for_owner, ->(owner) { where(owner: owner) }

    # Callbacks
    before_create :generate_client_id
    before_update :set_deactivated_at, if: :will_save_change_to_active?

    def deactivate!
      update!(active: false, deactivated_at: Time.current)
    end

    def activate!
      update!(active: true, deactivated_at: nil)
    end

    def active?
      active && deactivated_at.nil?
    end

    # OAuth configuration helpers
    def redirect_uris_array
      redirect_uris.to_s.split(/\s+/).map(&:strip).reject(&:blank?)
    end

    def scopes_array
      scopes.to_s.split(/\s+/).map(&:strip).reject(&:blank?)
    end

    def grant_types_array
      grant_types.to_s.split(/\s+/).map(&:strip).reject(&:blank?)
    end

    def response_types_array
      response_types.to_s.split(/\s+/).map(&:strip).reject(&:blank?)
    end

    def code_challenge_methods_array
      code_challenge_methods.to_s.split(/\s+/).map(&:strip).reject(&:blank?)
    end

    def supports_grant_type?(grant_type)
      grant_types_array.include?(grant_type.to_s)
    end

    def supports_response_type?(response_type)
      response_types_array.include?(response_type.to_s)
    end

    def supports_pkce_method?(method)
      return false unless require_pkce?
      code_challenge_methods_array.include?(method.to_s)
    end

    def valid_redirect_uri?(uri)
      redirect_uris_array.include?(uri.to_s)
    end

    def confidential?
      client_type == "confidential"
    end

    def public?
      client_type == "public"
    end

    # Generate a new client secret credential
    def create_client_secret!(name: "Default Secret", **options)
      client_secret_credentials.create!({
        name: name,
        client_id: client_id,
        scopes: scopes
      }.merge(options))
    end

    # Get the primary (first active) client secret
    def primary_client_secret
      client_secret_credentials.active.first
    end

    # Client secret rotation support
    def rotate_client_secret!(new_secret_name: "Rotated Secret #{Time.current.strftime('%Y%m%d')}", client_secret: SecureRandom.hex(32))
      transaction do
        # Create new secret
        new_secret = create_client_secret!(name: new_secret_name, client_secret: client_secret)

        # Deactivate old secrets (but don't delete for audit trail)
        client_secret_credentials.where.not(id: new_secret.id).update_all(
          active: false,
          revoked_at: Time.current
        )

        new_secret
      end
    end

    # Check if client can authenticate with given secret
    def authenticate_client_secret(secret)
      client_secret_credentials.active.find { |cred| cred.authenticate_client_secret(secret) }
    end

    private

    def generate_client_id
      self.client_id ||= SecureRandom.hex(16)
    end

    def set_deactivated_at
      if will_save_change_to_active?
        if active?
          self.deactivated_at = nil
        else
          self.deactivated_at = Time.current if deactivated_at.nil?
        end
      end
    end
  end
end
