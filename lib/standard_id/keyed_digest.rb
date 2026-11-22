require "openssl"

module StandardId
  # The secrets StandardId keys its stored token digests on, and the
  # comparisons that accept any of them.
  #
  # Every keyed digest the engine stores (Session#lookup_hash and
  # #token_digest, CodeChallenge#code_digest, AuthorizationCode#code_hash,
  # ClientApplication#registration_access_token_digest) is derived from
  # `secret_key_base`, as is the HS256/384/512 JWT signing key, so rotating
  # that secret used to strand every one of them: all users signed out, every
  # in-flight code, registration access token and HMAC-signed JWT dead.
  #
  # `config.previous_secret_key_bases` is the opt-in that prevents it.
  # Digests are always WRITTEN under the current secret; they are READ (looked
  # up and verified) under the current secret and then each previous one, in
  # order. Rails offers the same idea for its own derived secrets
  # (`Rails.application.message_verifiers.rotate(secret_key_base: old)`,
  # `config.action_dispatch.cookies_rotations`), but keeps no list of previous
  # `secret_key_base` values a gem could read, hence the setting. The shape
  # mirrors Rodauth's `hmac_old_secret`.
  #
  # Long-lived credentials (session tokens, registration access tokens) that
  # authenticate under a previous secret are re-keyed on the spot (.rekey), so
  # an old secret only has to stay listed until every such credential has been
  # used once since the rotation, or has expired.
  module KeyedDigest
    module_function

    # The secret new digests are written under. Read through
    # Rails.configuration, as the stored digests always have been, so the
    # values for the current secret are unchanged by this module.
    def current_secret
      Rails.configuration.secret_key_base
    end

    # Current secret first, then `config.previous_secret_key_bases` (blank
    # entries and duplicates of an earlier secret dropped). With no previous
    # secrets configured this is one element and every caller does exactly the
    # work it did before.
    def secrets
      [current_secret, *previous_secrets].uniq
    end

    # `config.previous_secret_key_bases` as strings, blank entries dropped.
    # JwtService also verifies HMAC-signed JWTs under these.
    def previous_secrets
      Array(StandardId.config.previous_secret_key_bases).map(&:to_s).reject(&:blank?)
    end

    # HMAC-SHA256 of +data+ under +secret+, hex-encoded. Callers domain-separate
    # by prefixing +data+ with a versioned label of their own.
    def hmac_hexdigest(data, secret: current_secret)
      OpenSSL::HMAC.hexdigest("SHA256", secret, data)
    end

    # The value a digest may be stored as, once per accepted secret: yields
    # each secret (current first) and collects the block's results. Use it to
    # query an indexed digest column for every candidate at once.
    def candidates
      secrets.map { |secret| yield secret }
    end

    # Rewrites the digest columns of a row that just authenticated under a
    # previous secret to their current-secret values, in a single UPDATE that
    # applies only while the row still holds +from+ (so a concurrent re-key,
    # rotation or revocation write is never overwritten). Runs no callbacks,
    # touches no timestamps and publishes nothing.
    #
    # It is an optimisation of the rotation window, never part of
    # authentication: any error (a read-only replica, a lock timeout, a missing
    # column) is logged without the digests and swallowed, and a savepoint
    # keeps a failed statement from aborting a surrounding transaction.
    #
    # @param model [Class<ActiveRecord::Base>]
    # @param id [Object] the row's primary key
    # @param from [Hash] column => value the row must still hold
    # @param to [Hash] column => current-secret value
    # @return [Boolean] whether the row was rewritten
    def rekey(model, id:, from:, to:)
      update = -> { model.unscoped.where(model.primary_key => id, **from).update_all(to) }
      rows = model.with_connection(&:transaction_open?) ? model.transaction(requires_new: true) { update.call } : update.call
      rows == 1
    rescue StandardError => e
      StandardId.logger.warn(
        "[StandardId::KeyedDigest] Could not re-key #{model.name} #{id} under the current secret_key_base " \
        "(#{e.class}); it still authenticates under the previous secret"
      )
      false
    end

    # Constant-time check of +stored+ against every candidate. Compares against
    # all of them rather than stopping at the first match, so the response time
    # does not say which secret a digest was written under.
    #
    # @return [Boolean] false for a blank +stored+ value
    def secure_match?(stored, candidates)
      return false if stored.blank?

      candidates.map { |candidate| ActiveSupport::SecurityUtils.secure_compare(stored.to_s, candidate.to_s) }.any?
    end
  end
end
