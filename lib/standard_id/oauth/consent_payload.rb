module StandardId
  module Oauth
    # Tamper-proof carrier for the original /authorize parameters across the
    # consent hand-off (API authorize -> WebEngine consent screen -> resume).
    #
    # Mirrors the OTP flow's use of Rails.application.message_verifier: the
    # params are signed (not encrypted — they are not secret, but must not be
    # mutable by the user) and expire so a stale consent link can't be replayed
    # indefinitely. redirect_uri and PKCE are revalidated when the resumed
    # /authorize re-runs, so signing here defends the integrity of the carried
    # values, not the eventual code issuance.
    module ConsentPayload
      VERIFIER_PURPOSE = :standard_id_oauth_consent
      # Generous TTL: the user may take a while to read the consent screen.
      DEFAULT_EXPIRY = 600 # seconds (10 minutes)

      module_function

      def encode(params, expires_in: DEFAULT_EXPIRY)
        verifier.generate(params.to_h.symbolize_keys, expires_in: expires_in.seconds)
      end

      # Returns the params Hash (symbolized keys) or nil if the payload is
      # missing, tampered, or expired.
      def decode(token)
        return nil if token.blank?

        verifier.verified(token)&.symbolize_keys
      end

      def verifier
        Rails.application.message_verifier(VERIFIER_PURPOSE)
      end
    end
  end
end
