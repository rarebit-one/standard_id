require "securerandom"

module StandardId
  class ClientSecretCredential < ApplicationRecord
    include StandardId::Credentiable

    belongs_to :client_application, class_name: "StandardId::ClientApplication"
    has_secure_password :client_secret

    before_validation :set_client_id_from_client, on: :create
    before_validation :ensure_client_secret, on: :create

    validates :name, presence: true
    validates :client_id, presence: true
    validates :active, inclusion: { in: [true, false] }

    scope :active, -> { where(active: true, revoked_at: nil) }

    def revoke!
      update!(active: false, revoked_at: Time.current)
      emit_revoked_event
    end

    def active?
      active && revoked_at.nil?
    end

    def scopes_array
      (scopes || "").split(" ").map(&:strip).reject(&:blank?)
    end

    def default_redirect_uri
      redirect_uris&.split(" ")&.first
    end

    # Effective configuration with per-secret override fallback
    def effective_scopes_array
      return scopes_array if scopes.present?
      client_application.scopes_array
    end

    def effective_redirect_uris_array
      return redirect_uris.to_s.split(/\s+/).map(&:strip).reject(&:blank?) if redirect_uris.present?
      client_application.redirect_uris_array
    end

    def effective_default_redirect_uri
      effective_redirect_uris_array.first
    end

    private

    def set_client_id_from_client
      self.client_id = client_application&.client_id if client_id.blank?
    end

    def ensure_client_secret
      self.client_secret ||= SecureRandom.hex(32)
    end

    def emit_revoked_event
      StandardId::Events.publish(
        StandardId::Events::CREDENTIAL_CLIENT_SECRET_REVOKED,
        credential: self,
        client_application: client_application,
        client_id: client_id,
        revoked_at: revoked_at
      )
    end

    # Note: We intentionally do not enforce subset validation for per-secret overrides here.
    # If needed later, we can introduce a configuration flag to enable enforcement.
  end
end
