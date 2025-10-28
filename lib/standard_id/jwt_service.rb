require "jwt"

module StandardId
  class JwtService
    ALGORITHM = "HS256"
    RESERVED_JWT_KEYS = %w[sub client_id scope grant_type exp iat aud iss nbf jti]
    BASE_SESSION_FIELDS = [:account_id, :client_id, :scopes, :grant_type].freeze

    def self.session_class
      Struct.new(*(BASE_SESSION_FIELDS + claim_resolver_keys), keyword_init: true) do
        def active?
          true
        end
      end
    end

    def self.encode(payload, expires_in: 1.hour)
      payload[:exp] = expires_in.from_now.to_i
      payload[:iat] = Time.current.to_i

      JWT.encode(payload, secret_key, ALGORITHM)
    end

    def self.decode(token)
      decoded = JWT.decode(token, secret_key, true, { algorithm: ALGORITHM })
      decoded.first.with_indifferent_access
    rescue JWT::DecodeError, JWT::ExpiredSignature, JWT::InvalidIatError
      nil
    end

    def self.decode_session(token)
      payload = decode(token)
      return unless payload

      scopes = if payload[:scope].is_a?(String)
        payload[:scope].split(" ")
      else
        Array(payload[:scope]).compact
      end

      session_class.new(
        **payload.slice(*claim_resolver_keys),
        account_id: payload[:sub],
        client_id: payload[:client_id],
        scopes: scopes,
        grant_type: payload[:grant_type],
      )
    end

    private

    def self.secret_key
      Rails.application.secret_key_base
    end

    def self.claim_resolver_keys
      resolvers = StandardId.config.oauth.claim_resolvers
      keys = if resolvers.respond_to?(:keys)
        resolvers.keys
      elsif resolvers.respond_to?(:to_h)
        resolvers.to_h.keys
      else
        []
      end
      keys.compact.map(&:to_sym).uniq.excluding(*RESERVED_JWT_KEYS)
    rescue StandardError
      []
    end
  end
end
