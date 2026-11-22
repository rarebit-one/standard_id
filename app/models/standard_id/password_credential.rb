module StandardId
  class PasswordCredential < ApplicationRecord
    include StandardId::Credentiable
    include StandardId::PasswordStrength

    has_secure_password

    generates_token_for :remember_me, expires_in: 30.days do
      password_digest
    end

    generates_token_for :password_reset, expires_in: 20.minutes do
      password_digest
    end

    validates :login, presence: true, uniqueness: true
    validates :password, confirmation: true, if: :validate_password?

    # The bcrypt cost has_secure_password hashes a new password at, worked out
    # the way ActiveModel::SecurePassword does.
    def self.password_cost
      ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
    end

    # Re-hashes +password+ when the stored digest was made at a bcrypt cost
    # other than .password_cost, so raising BCrypt::Engine.cost reaches
    # existing passwords as their owners sign in instead of only new ones.
    # Every password login calls it once +password+ has authenticated; turn it
    # off with c.password.rehash_on_login = false.
    #
    # +authenticated_digest+ is the digest +password+ was checked against. The
    # write is one UPDATE conditional on the row still holding it, so a reset
    # that got there first wins and nothing changes. A caller that re-checks
    # the digest under a lock (EmailPassword::Authentication, Verification)
    # must call this after that check, inside the lock, or its own check would
    # see the new digest. Nothing is reloaded, so the caller's preloaded
    # associations survive.
    #
    # The digest is the fingerprint of the :remember_me and :password_reset
    # tokens, so a rehash invalidates the user's outstanding remember-me
    # cookies and reset links: mint any new one after calling this.
    #
    # Never raises: a failed rehash keeps the old digest and the login goes on.
    #
    # @return [Boolean] whether the digest was replaced
    def rehash_password(password, authenticated_digest = password_digest)
      return false unless StandardId.config.password.rehash_on_login && password_rehash_needed?

      previous_cost = BCrypt::Password.new(password_digest).cost
      attributes = { password_digest: BCrypt::Password.create(password, cost: self.class.password_cost), updated_at: Time.current }
      # The savepoint keeps a failed UPDATE from aborting the caller's
      # transaction (PostgreSQL refuses every later statement in it).
      rehashed = self.class.transaction(requires_new: true) do
        self.class.where(id: id, password_digest: authenticated_digest).update_all(attributes) == 1
      end
      return false unless rehashed

      assign_attributes(attributes)
      clear_attribute_changes(attributes.keys)
      # Held until the caller's transaction commits, so a login that rolls
      # back (a policy refusal inside EmailPassword::Authentication's lock)
      # reports no rehash.
      ActiveRecord.after_all_transactions_commit { publish_password_rehashed(previous_cost) }
      true
    rescue StandardError => e
      report_failure("rehash password credential #{id}", e)
      false
    end

    private

    def validate_password?
      password.present? || password_confirmation.present?
    end

    def password_rehash_needed?
      BCrypt::Password.new(password_digest).cost != self.class.password_cost
    rescue BCrypt::Errors::InvalidHash
      false
    end

    # The event carries the account: load the chain (a no-op where the caller
    # preloaded it) so a subscriber under strict loading can walk it.
    def publish_password_rehashed(previous_cost)
      ActiveRecord::Associations::Preloader.new(records: [self], associations: { credential: { identifier: :account } }).call
      StandardId::Events.publish(
        StandardId::Events::CREDENTIAL_PASSWORD_REHASHED,
        credential: self,
        account: account,
        previous_cost: previous_cost,
        cost: self.class.password_cost
      )
    rescue StandardError => e
      report_failure("publish CREDENTIAL_PASSWORD_REHASHED for password credential #{id}", e)
    end

    def report_failure(action, error)
      Rails.error.report(error, handled: true, source: "standard_id")
      logger = StandardId.logger
      return unless logger.respond_to?(:error)

      logger.error("[StandardId::PasswordCredential] Failed to #{action}: #{error.class}: #{error.message}")
    end
  end
end
