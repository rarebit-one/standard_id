module StandardId
  class EmailIdentifier < Identifier
    # `URI::MailTo::EMAIL_REGEXP` models the local part as one flat character
    # class that happens to include `.`, so it accepts dot placements RFC 5322
    # forbids in an unquoted local part: a leading dot, a trailing dot, and
    # consecutive dots. `a..b@example.com` passes it.
    #
    # ESPs do not. Postmark rejects such an address at send time with
    # `InvalidEmailRequestError`, so a typo accepted at sign-up surfaces much
    # later as a failed delivery job that no operator can act on — the address
    # is already stored and the user is long gone.
    #
    # Enforce the dot-atom rule instead: the local part is dot-separated atoms,
    # each at least one character. The domain pattern is `URI::MailTo`'s,
    # unchanged.
    LOCAL_PART = %r{[A-Za-z0-9!\#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!\#$%&'*+/=?^_`{|}~-]+)*}
    DOMAIN = /[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*/
    EMAIL_FORMAT = /\A#{LOCAL_PART}@#{DOMAIN}\z/

    normalizes :value, with: ->(e) { e.strip.downcase }

    # Scoped to a changed value so tightening the rule cannot strand an account
    # created under the looser one: an existing row keeps working until someone
    # actually edits the address. Without this, saving an unrelated attribute on
    # a grandfathered identifier would start raising.
    validates :value, format: { with: EMAIL_FORMAT }, if: :value_changed?
  end
end
