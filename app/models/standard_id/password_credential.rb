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

    # Why the next password change happens, published as
    # CREDENTIAL_PASSWORD_CHANGED's +reason+: the engine's reset flows set
    # :password_reset; otherwise it is :changed.
    attr_writer :password_change_reason

    # CREDENTIAL_PASSWORD_CHANGED, once an update that set a new password
    # commits: the engine's resets and any host code that assigns +password+.
    # Writing password_digest without going through +password=+ (a rehash of
    # the same password) does not count.
    #
    # The digest +password=+ made is kept until a commit, and published only
    # when it is the digest that commit left in the row. Nothing is decided at
    # save time, so a rolled-back savepoint inside the transaction, or a
    # rolled-back save retried later, still publishes when the new password
    # finally commits; a commit that did not write it publishes nothing.
    after_create_commit :forget_assigned_password
    after_update_commit :publish_password_changed, if: :password_change_committed?

    # has_secure_password's setter, remembering the digest it made so the
    # commit can tell a new password from a direct write of the digest. An
    # empty assignment changes nothing, as has_secure_password ignores it.
    # Under c.password.pepper the digest is made from the peppered password
    # (StandardId::PasswordPepper); without one, has_secure_password makes it.
    def password=(unencrypted_password)
      # has_secure_password's own test (nil clears, "" is ignored), so a
      # whitespace-only password is peppered like any other.
      if StandardId::PasswordPepper.current.present? && !unencrypted_password.nil? && !unencrypted_password.empty?
        @password = unencrypted_password
        self.password_digest = self.class.password_digest_for(unencrypted_password)
      else
        super
      end
      @assigned_password_digest = (password_digest if unencrypted_password.present?)
    end

    # has_secure_password's check, trying each pepper the digest may have been
    # made under (StandardId::PasswordPepper.candidates): the current one, the
    # previous ones, then none. Remembers which one matched, so
    # #rehash_password can move the digest to the current pepper. With no
    # pepper configured this is has_secure_password's own comparison.
    #
    # has_secure_password's +password_challenge+ validation compares the bare
    # password and does not know about the pepper; check a current password
    # with this method instead.
    #
    # @return [self, false]
    def authenticate_password(unencrypted_password)
      digest = password_digest
      return false if digest.blank?

      pepper = StandardId::PasswordPepper.matching_pepper(digest, unencrypted_password)
      return false if pepper.nil?

      @authenticated_pepper = [digest, pepper]
      self
    end
    alias_method :authenticate, :authenticate_password

    # The bcrypt cost has_secure_password hashes a new password at, worked out
    # the way ActiveModel::SecurePassword does.
    def self.password_cost
      ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
    end

    # A new digest for +password+: bcrypt at .password_cost of the password
    # under the current pepper (the bare password when none is set).
    def self.password_digest_for(password)
      peppered = StandardId::PasswordPepper.apply(password, StandardId::PasswordPepper.current)
      BCrypt::Password.create(peppered, cost: password_cost)
    end

    # Re-hashes +password+ when the stored digest was made at a bcrypt cost
    # other than .password_cost, or under a pepper other than the current one
    # (a previous pepper, or none: see StandardId::PasswordPepper), so raising
    # BCrypt::Engine.cost, or setting or rotating c.password.pepper, reaches
    # existing passwords as their owners sign in instead of only new ones.
    # Every password login calls it once +password+ has authenticated; turn it
    # off with c.password.rehash_on_login = false. It is not a password change:
    # CREDENTIAL_PASSWORD_CHANGED is not published and no notice is sent.
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
      return false unless StandardId.config.password.rehash_on_login

      pepper_changed = pepper_rehash_needed?(password, authenticated_digest)
      return false if pepper_changed.nil?
      return false unless pepper_changed || password_rehash_needed?

      previous_cost = BCrypt::Password.new(password_digest).cost
      attributes = { password_digest: self.class.password_digest_for(password), updated_at: Time.current }
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
      ActiveRecord.after_all_transactions_commit { publish_password_rehashed(previous_cost, pepper_changed) }
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

    # Whether +digest+ holds +password+ under a pepper other than the current
    # one: true or false, or nil when +password+ does not match +digest+ at
    # all, which must not be re-hashed. Always false while no pepper is
    # configured, without another bcrypt comparison, so a host without one
    # rehashes exactly as before. Reuses the pepper #authenticate matched for
    # this digest; otherwise works it out again.
    def pepper_rehash_needed?(password, digest)
      return false unless StandardId::PasswordPepper.enabled?

      pepper = if @authenticated_pepper&.first == digest
        @authenticated_pepper.last
      else
        StandardId::PasswordPepper.matching_pepper(digest, password)
      end
      return nil if pepper.nil?

      pepper != StandardId::PasswordPepper.current
    rescue BCrypt::Errors::InvalidHash
      nil
    end

    # The event carries the account: load the chain (a no-op where the caller
    # preloaded it) so a subscriber under strict loading can walk it.
    def publish_password_rehashed(previous_cost, pepper_changed = false)
      ActiveRecord::Associations::Preloader.new(records: [self], associations: { credential: { identifier: :account } }).call
      StandardId::Events.publish(
        StandardId::Events::CREDENTIAL_PASSWORD_REHASHED,
        credential: self,
        account: account,
        previous_cost: previous_cost,
        cost: self.class.password_cost,
        pepper_changed: pepper_changed
      )
    rescue StandardError => e
      report_failure("publish CREDENTIAL_PASSWORD_REHASHED for password credential #{id}", e)
    end

    def report_failure(action, error)
      StandardId::ErrorReporting.report(error, action: action)
      logger = StandardId.logger
      return unless logger.respond_to?(:error)

      logger.error("[StandardId::PasswordCredential] Failed to #{action}: #{error.class}: #{error.message}")
    end

    def forget_assigned_password
      @assigned_password_digest = nil
    end

    # Read from the row rather than the record: after a rollback the record
    # can still hold the assigned digest while the row does not.
    def password_change_committed?
      @assigned_password_digest.present? &&
        self.class.where(id: id).pick(:password_digest) == @assigned_password_digest
    end

    # The change has committed, so a failing subscriber must not raise out of
    # the caller's save; report and carry on, as the reset flows do for
    # CREDENTIAL_PASSWORD_RESET_COMPLETED. The event carries the account: load
    # the chain so a subscriber under strict loading can walk it.
    #
    # +credential_id+ is explicit, as on PASSWORD_VALIDATED: the record keys
    # are left out under events.publish_records = false, and so are their
    # _id/_gid companions when publish_record_identifiers is off too.
    def publish_password_changed
      reason = @password_change_reason || :changed
      forget_assigned_password
      @password_change_reason = nil
      ActiveRecord::Associations::Preloader.new(records: [self], associations: { credential: { identifier: :account } }).call
      StandardId::Events.publish(
        StandardId::Events::CREDENTIAL_PASSWORD_CHANGED,
        credential: self,
        credential_id: id,
        account: credential&.account,
        reason: reason
      )
    rescue StandardError => e
      report_failure("publish CREDENTIAL_PASSWORD_CHANGED for password credential #{id}", e)
    end
  end
end
