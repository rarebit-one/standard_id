module StandardId
  class AuthorizationCode < ApplicationRecord
    self.table_name = "standard_id_authorization_codes"

    belongs_to :account, class_name: StandardId.config.account_class_name, optional: true

    # Validations
    validates :code_hash, presence: true, uniqueness: true
    validates :client_id, presence: true
    validates :redirect_uri, presence: true
    validates :issued_at, presence: true
    validates :expires_at, presence: true

    scope :unexpired, -> { where("expires_at > ?", Time.current) }
    scope :unused, -> { where(consumed_at: nil) }

    before_validation :set_issued_and_expiry, on: :create

    def self.issue!(plaintext_code:, client_id:, redirect_uri:, scope: nil, audience: nil, account: nil, code_challenge: nil, code_challenge_method: nil, nonce: nil, metadata: {})
      # Fail fast: reject unsupported PKCE methods at issuance rather than
      # storing a code that will always fail at redemption time.
      if code_challenge.present?
        unless code_challenge_method.to_s.downcase == "s256"
          raise StandardId::InvalidRequestError, "Unsupported code_challenge_method: only S256 is allowed"
        end
      end

      # Hash the code_challenge for defense-in-depth (RAR-58).
      # The stored value is SHA256(S256_challenge), where S256_challenge is
      # base64url(SHA256(verifier)). This is intentionally a double-hash:
      # S256 derives the challenge from the verifier, and we hash again for storage.
      hashed_challenge = code_challenge.present? ? Digest::SHA256.hexdigest(code_challenge) : nil

      create!(
        account: account,
        code_hash: hash_for(plaintext_code),
        client_id: client_id,
        redirect_uri: redirect_uri,
        scope: scope,
        audience: audience,
        code_challenge: hashed_challenge,
        code_challenge_method: code_challenge_method,
        nonce: nonce,
        issued_at: Time.current,
        expires_at: Time.current + default_ttl,
        metadata: metadata || {}
      )
    end

    def self.lookup(plaintext_code)
      find_by(code_hash: hash_for(plaintext_code))
    end

    def self.hash_for(plaintext_code)
      Digest::SHA256.hexdigest("#{plaintext_code}:#{Rails.configuration.secret_key_base}")
    end

    def self.default_ttl
      10.minutes
    end

    def valid_for_client?(client_id)
      self.client_id == client_id && consumed_at.nil? && !expired?
    end

    def expired?
      expires_at <= Time.current
    end

    def pkce_valid?(code_verifier)
      return true if code_challenge.blank?

      return false if code_verifier.blank?

      # Only S256 is supported (OAuth 2.1). The "plain" method is rejected
      # because it transmits the verifier in cleartext, defeating PKCE's purpose.
      return false unless (code_challenge_method || "").downcase == "s256"

      # Recompute: SHA256(base64url(SHA256(verifier))) to match stored hash
      expected = Digest::SHA256.hexdigest(
        Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier)).delete("=")
      )
      ActiveSupport::SecurityUtils.secure_compare(expected, code_challenge)
    end

    def mark_as_used!
      with_lock do
        raise StandardId::InvalidGrantError, "Authorization code already used" if consumed_at.present?
        raise StandardId::InvalidGrantError, "Authorization code expired" if expired?
        update!(consumed_at: Time.current)
      end
    end

    private

    def set_issued_and_expiry
      self.issued_at ||= Time.current
      self.expires_at ||= issued_at + self.class.default_ttl
    end
  end
end
