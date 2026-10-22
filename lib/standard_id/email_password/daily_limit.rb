require "digest"

module StandardId
  module EmailPassword
    # Per-address caps over a 24-hour window, on top of the controller's short
    # per-IP / per-email limits. Those bound bursts; these bound what one
    # address can be put through in a day, however patiently it is spread out.
    # The limits are `c.rate_limits.email_password_*_per_day` (see the schema).
    #
    # Counted per normalised address whether or not an account exists, so a cap
    # being reached reveals nothing. Counters live in the engine's rate-limit
    # store. The window is fixed from the first event: `increment(expires_in:)`
    # only sets the expiry when it creates the entry.
    #
    # Check-then-record is not atomic, so concurrent requests can overshoot a
    # cap by a few. That is fine for an abuse bound; do not use these as quotas.
    module DailyLimit
      WINDOW = 24.hours

      LIMIT_FIELDS = {
        failed_verification: :email_password_failed_verifications_per_day,
        code_issued: :email_password_codes_per_day,
        reset_requested_network: :email_password_reset_requests_per_network_per_day,
        reset_requested: :email_password_reset_requests_per_day
      }.freeze

      class << self
        def limit(kind)
          StandardId.config.rate_limits.public_send(LIMIT_FIELDS.fetch(kind)).to_i
        end

        # +scope+ further partitions the counter (the client key for
        # :reset_requested_network).
        def exceeded?(kind, email, scope: nil)
          count(kind, email, scope: scope) >= limit(kind)
        end

        def count(kind, email, scope: nil)
          store.read(key(kind, email, scope: scope)).to_i
        end

        # Records one event; returns the new count.
        def record!(kind, email, scope: nil)
          store.increment(key(kind, email, scope: scope), 1, expires_in: WINDOW).to_i
        end

        # Records one event unless the cap is already reached. Returns true when
        # the event may proceed.
        def consume!(kind, email, scope: nil)
          return false if exceeded?(kind, email, scope: scope)

          record!(kind, email, scope: scope) <= limit(kind)
        end

        def key(kind, email, scope: nil)
          LIMIT_FIELDS.fetch(kind) # unknown kinds raise
          subject = [EmailPassword.normalize_email(email), scope].compact.join("|")
          "standard_id:email-password-daily:#{kind}:#{Digest::SHA256.hexdigest(subject)}"
        end

        def store
          StandardId::RateLimiter::STORE
        end
      end
    end
  end
end
