require "openssl"

module StandardId
  # The secrets StandardId keys its stored token digests on, and the
  # comparisons that accept any of them.
  #
  # Every keyed digest the engine stores (Session#lookup_hash and
  # #token_digest, CodeChallenge#code_digest, AuthorizationCode#code_hash,
  # ClientApplication#registration_access_token_digest) is derived from
  # `secret_key_base`, so rotating that secret used to strand every one of
  # them: all users signed out, every in-flight code and registration access
  # token dead.
  #
  # `config.previous_secret_key_bases` is the opt-in that prevents it.
  # Digests are always WRITTEN under the current secret; they are READ (looked
  # up and verified) under the current secret and then each previous one, in
  # order. Rails offers the same idea for its own derived secrets
  # (`Rails.application.message_verifiers.rotate(secret_key_base: old)`,
  # `config.action_dispatch.cookies_rotations`), but keeps no list of previous
  # `secret_key_base` values a gem could read, hence the setting. The shape
  # mirrors Rodauth's `hmac_old_secret`.
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
      previous = Array(StandardId.config.previous_secret_key_bases).map(&:to_s).reject(&:blank?)
      [current_secret, *previous].uniq
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
