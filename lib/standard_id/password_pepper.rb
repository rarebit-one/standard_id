require "concurrent/delay"
require "openssl"

module StandardId
  # The secret mixed into every password before bcrypt sees it
  # (`c.password.pepper`), so a leaked database alone is not enough to crack
  # the digests: the pepper lives in the app's credentials, not in the rows.
  #
  # A peppered digest is bcrypt(HMAC-SHA256(pepper, password)), hex-encoded,
  # never bcrypt(password + pepper): bcrypt reads only the first 72 bytes, so
  # an appended pepper would be cut off a long password, and a raw HMAC can
  # contain the NUL byte bcrypt stops at. The hex form is 64 bytes of [0-9a-f].
  #
  # Digests are WRITTEN under the current pepper and READ under the current
  # pepper, then each of `c.password.previous_peppers`, then with no pepper at
  # all, so turning the pepper on, or rotating it, locks nobody out: a login
  # that matched anything but the current pepper re-hashes under it
  # (PasswordCredential#rehash_password). With no pepper configured there is
  # one candidate, the bare password, and every caller does exactly what
  # has_secure_password did. The shape mirrors Rodauth's password_pepper.
  #
  # Losing the pepper makes every digest made under it unverifiable: each of
  # those users has to reset their password. Keep it with secret_key_base.
  module PasswordPepper
    # The candidate meaning "no pepper": the bare password.
    UNPEPPERED = ""

    # A digest to compare against when no credential exists, so a miss costs
    # the same bcrypt work as a wrong password (see .dummy_authenticate).
    DUMMY_DIGEST = Concurrent::Delay.new { BCrypt::Password.create("").freeze }

    module_function

    # The pepper new digests are written under; UNPEPPERED when none is set.
    def current
      StandardId.config.password.pepper.to_s
    end

    # Whether any pepper is configured, current or previous. When false the
    # engine never looks past has_secure_password's own behaviour.
    def enabled?
      current.present? || previous.any?
    end

    # The peppers a stored digest may have been made under, current first,
    # then `c.password.previous_peppers`, then UNPEPPERED unless
    # `c.password.accept_unpeppered_passwords` is off. Blank and repeated
    # entries are dropped. The unpeppered candidate is always kept while no
    # current pepper is set, so the setting cannot lock everyone out.
    def candidates
      list = [current, *previous]
      list << UNPEPPERED if current.empty? || StandardId.config.password.accept_unpeppered_passwords
      list.uniq
    end

    # What bcrypt hashes for +password+ under +pepper+.
    def apply(password, pepper)
      password = password.to_s
      pepper.empty? ? password : OpenSSL::HMAC.hexdigest("SHA256", pepper, password)
    end

    # The candidate +password+ matches +digest+ under, or nil when it matches
    # none. Stops at the first match: once the password is right, how long the
    # check took says nothing a caller did not already know. A wrong password
    # costs one bcrypt comparison per candidate, which .dummy_authenticate
    # matches.
    def matching_pepper(digest, password)
      stored = BCrypt::Password.new(digest)
      candidates.find { |pepper| stored.is_password?(apply(password, pepper)) }
    end

    # The work of a wrong password against a real digest, done against
    # DUMMY_DIGEST, for a login whose credential does not exist: timing must
    # not reveal whether an address is registered. One comparison per
    # candidate, as .matching_pepper makes for a wrong password.
    #
    # @return [nil]
    def dummy_authenticate(password)
      stored = BCrypt::Password.new(DUMMY_DIGEST.value)
      candidates.each { |pepper| stored.is_password?(apply(password, pepper)) }
      nil
    end

    def previous
      Array(StandardId.config.password.previous_peppers).map(&:to_s).reject(&:empty?)
    end
  end
end
