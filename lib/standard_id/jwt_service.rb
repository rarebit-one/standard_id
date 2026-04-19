require "jwt"
require "concurrent/delay"
require "concurrent/atomic/atomic_reference"
require "openssl"
require "digest"

module StandardId
  class JwtService
    RESERVED_JWT_KEYS = %i[sub client_id scope grant_type exp iat aud iss nbf jti]
    BASE_SESSION_FIELDS = %i[account_id client_id scopes grant_type aud claims]

    # Supported signing algorithms categorized by type
    # Symmetric: use shared secret (Rails.application.secret_key_base)
    # Asymmetric: use key pairs (RSA or EC private key)
    SUPPORTED_ALGORITHMS = {
      # HMAC (symmetric)
      "HS256" => { type: :symmetric },
      "HS384" => { type: :symmetric },
      "HS512" => { type: :symmetric },
      # RSA (asymmetric)
      "RS256" => { type: :asymmetric, key_class: OpenSSL::PKey::RSA },
      "RS384" => { type: :asymmetric, key_class: OpenSSL::PKey::RSA },
      "RS512" => { type: :asymmetric, key_class: OpenSSL::PKey::RSA },
      # ECDSA (asymmetric)
      "ES256" => { type: :asymmetric, key_class: OpenSSL::PKey::EC },
      "ES384" => { type: :asymmetric, key_class: OpenSSL::PKey::EC },
      "ES512" => { type: :asymmetric, key_class: OpenSSL::PKey::EC }
    }.freeze

    SESSION_CLASS = Concurrent::Delay.new do
      Struct.new(*(BASE_SESSION_FIELDS + claim_resolver_keys), keyword_init: true) do
        def active?
          true
        end
      end
    end

    @signing_key_ref = Concurrent::AtomicReference.new
    @key_id_ref = Concurrent::AtomicReference.new
    @previous_keys_ref = Concurrent::AtomicReference.new
    @jwks_ref = Concurrent::AtomicReference.new

    def self.session_class
      SESSION_CLASS.value
    end

    def self.algorithm
      StandardId.config.oauth.signing_algorithm.to_s.upcase
    end

    def self.algorithm_config
      SUPPORTED_ALGORITHMS[algorithm] || raise(ArgumentError, "Unsupported algorithm: #{algorithm}. Supported: #{SUPPORTED_ALGORITHMS.keys.join(', ')}")
    end

    def self.asymmetric?
      algorithm_config[:type] == :asymmetric
    end

    def self.signing_key
      if asymmetric?
        @signing_key_ref.get || begin
          computed = parse_private_key(StandardId.config.oauth.signing_key)
          @signing_key_ref.compare_and_set(nil, computed)
          @signing_key_ref.get
        end
      else
        Rails.application.secret_key_base
      end
    end

    def self.verification_key
      if asymmetric?
        key = signing_key
        # For EC keys, the key itself can be used for verification
        # For RSA keys, we extract the public key
        key.is_a?(OpenSSL::PKey::EC) ? key : key.public_key
      else
        Rails.application.secret_key_base
      end
    end

    def self.key_id
      return nil unless asymmetric?

      # Generate stable key ID from public key fingerprint
      # Use public_to_pem which works for both RSA and EC keys
      @key_id_ref.get || begin
        computed = Digest::SHA256.hexdigest(signing_key.public_to_pem)[0..7]
        @key_id_ref.compare_and_set(nil, computed)
        @key_id_ref.get
      end
    end

    def self.previous_keys
      return [] unless asymmetric?

      @previous_keys_ref.get || begin
        computed = Array(StandardId.config.oauth.previous_signing_keys).filter_map do |entry|
          parse_previous_key_entry(entry)
        rescue StandardError
          nil
        end
        @previous_keys_ref.compare_and_set(nil, computed)
        @previous_keys_ref.get
      end
    end

    def self.all_verification_keys
      return [] unless asymmetric?

      [{ kid: key_id, key: verification_key, algorithm: algorithm }] + previous_keys
    end

    # NOTE: Individual resets are atomic but the group is not — a concurrent
    # reader between two .set(nil) calls may see a mix of old and new values.
    # This is acceptable: key rotation is an infrequent operator action and
    # the worst case is one request using a stale (but still valid) key.
    def self.reset_cached_key!
      @key_id_ref.set(nil)
      @signing_key_ref.set(nil)
      @previous_keys_ref.set(nil)
      @jwks_ref.set(nil)
    end

    def self.encode(payload, expires_in: nil, expires_at: nil)
      payload[:exp] = if expires_at
        expires_at.to_i
      else
        (expires_in || 1.hour).from_now.to_i
      end
      payload[:iat] = Time.current.to_i
      payload[:iss] ||= StandardId.config.issuer if StandardId.config.issuer.present?

      headers = {}
      headers[:kid] = key_id if asymmetric?

      JWT.encode(payload, signing_key, algorithm, headers)
    end

    # Decodes and verifies a JWT.
    #
    # When `allowed_audiences` is provided, the token's `aud` claim is
    # verified against the list; a mismatch raises
    # StandardId::InvalidAudienceError. Without the argument, audience is
    # not checked at decode time (many decode call sites legitimately do
    # not care about aud — e.g. revocation, refresh rotation — and rely on
    # the AudienceVerification concern at the controller layer for
    # endpoint-specific enforcement).
    #
    # Other decode failures (bad signature, expired, wrong issuer) return
    # nil, as before.
    def self.decode(token, allowed_audiences: nil)
      options = { algorithms: [algorithm] }

      if StandardId.config.issuer.present?
        options[:iss] = StandardId.config.issuer
        options[:verify_iss] = true
      end

      if allowed_audiences.present?
        options[:aud] = Array(allowed_audiences).map(&:to_s)
        options[:verify_aud] = true
      end

      if asymmetric? && previous_keys.any?
        # Include algorithms from previous keys for cross-algorithm rotation
        prev_algorithms = previous_keys.filter_map { |k| k[:algorithm] }
        options[:algorithms] = ([algorithm] + prev_algorithms).uniq

        # Build a JWKS set with all active keys for kid-based matching
        jwk_set = JWT::JWK::Set.new
        all_verification_keys.each do |entry|
          jwk_set << JWT::JWK.new(entry[:key], kid: entry[:kid])
        end
        options[:jwks] = jwk_set

        begin
          decoded = JWT.decode(token, nil, true, options)
          return decoded.first.with_indifferent_access
        rescue JWT::InvalidAudError
          # InvalidAudError is a JWT::DecodeError subclass — catch it first
          # and surface as the engine's audience error so callers can
          # distinguish aud failures from generic decode failures.
          raise StandardId::InvalidAudienceError.new(
            required: Array(allowed_audiences).map(&:to_s),
            actual: extract_unverified_audience(token)
          )
        rescue JWT::DecodeError, JWT::ExpiredSignature, JWT::InvalidIatError, JWT::InvalidIssuerError
          return nil
        end
      end

      decoded = JWT.decode(token, verification_key, true, options)
      decoded.first.with_indifferent_access
    rescue JWT::InvalidAudError
      raise StandardId::InvalidAudienceError.new(
        required: Array(allowed_audiences).map(&:to_s),
        actual: extract_unverified_audience(token)
      )
    rescue JWT::DecodeError, JWT::ExpiredSignature, JWT::InvalidIatError, JWT::InvalidIssuerError
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
        aud: payload[:aud],
        claims: payload.to_h
      )
    end

    def self.jwks
      return nil unless asymmetric?

      @jwks_ref.get || begin
        computed = begin
          exported_keys = all_verification_keys.map do |entry|
            jwk = JWT::JWK.new(entry[:key], kid: entry[:kid]).export
            jwk.merge(alg: entry[:algorithm], use: "sig")
          end
          { keys: exported_keys }
        end
        @jwks_ref.compare_and_set(nil, computed)
        @jwks_ref.get
      end
    end

    # Low-level primitive: sign a payload into a JWT.
    #
    # Unlike .encode, this method does NOT consult StandardId config. The caller
    # supplies the algorithm and key directly, and controls the full payload.
    # No issuer, audience, or iat/exp is added automatically (except when
    # expires_in is provided).
    #
    # @param payload [Hash] the JWT payload (claims)
    # @param algorithm [String] JWT algorithm, e.g. "HS256", "RS256", "ES256"
    # @param key [String, OpenSSL::PKey::PKey] signing key (String for HMAC,
    #   OpenSSL private key for RSA/EC)
    # @param expires_in [Integer, nil] seconds until expiration; sets the `exp`
    #   claim if provided. Caller-supplied `exp` in payload is preserved.
    # @param extra_headers [Hash] additional JWT header fields (e.g. kid:)
    # @return [String] the encoded JWT token
    def self.sign(payload, algorithm:, key:, expires_in: nil, **extra_headers)
      alg = algorithm.to_s
      # Reject the "none" alg explicitly. Without this guard, a caller who
      # passes algorithm: "none" (or "NONE") would produce an unsigned token
      # with the expected structure, turning this primitive into a footgun
      # for downstream verify paths that trust any successfully-decoded JWT.
      if alg.casecmp?("none")
        raise ArgumentError, "Algorithm 'none' is not permitted — unsigned tokens cannot be verified"
      end

      payload = payload.dup
      if expires_in && !payload.key?(:exp) && !payload.key?("exp")
        payload[:exp] = (Time.now + expires_in).to_i
      end
      JWT.encode(payload, key, alg, extra_headers)
    end

    # Low-level primitive: verify a JWT and return its payload.
    #
    # Unlike .decode, this method does NOT consult StandardId config and does
    # NOT return nil on failure — it raises StandardId::InvalidTokenError (or
    # a subclass) so callers get specific failure info.
    #
    # @param token [String] the JWT token
    # @param algorithm [String, Array<String>] allowed algorithm(s)
    # @param key [String, OpenSSL::PKey::PKey, Array] verification key, or an
    #   array of keys to try in order (for rotation scenarios)
    # @param allowed_audiences [Array<String>, String, nil] if provided, the
    #   `aud` claim is verified against this list
    # @param verify_expiration [Boolean] verify the `exp` claim (default true)
    # @param verify_not_before [Boolean] verify the `nbf` claim (default true)
    # @return [Hash] the decoded payload (with indifferent access)
    # @raise [StandardId::ExpiredTokenError] when the token has expired
    # @raise [StandardId::InvalidAlgorithmError] when the token's algorithm
    #   is not in the allowed list
    # @raise [StandardId::InvalidAudienceTokenError] when the aud claim does
    #   not match allowed_audiences
    # @raise [StandardId::InvalidSignatureError] when the signature is invalid
    # @raise [StandardId::InvalidTokenError] for any other decode failure
    def self.verify(token, algorithm:, key:, allowed_audiences: nil, verify_expiration: true, verify_not_before: true)
      algorithms = Array(algorithm).map(&:to_s)
      keys = key.is_a?(Array) ? key : [key]
      raise InvalidTokenError, "At least one verification key is required" if keys.empty?

      options = {
        algorithms: algorithms,
        verify_expiration: verify_expiration,
        verify_not_before: verify_not_before
      }

      if allowed_audiences
        options[:aud] = Array(allowed_audiences)
        options[:verify_aud] = true
      end

      last_error = nil
      keys.each do |candidate|
        begin
          decoded = JWT.decode(token, candidate, true, options)
          return decoded.first.with_indifferent_access
        rescue JWT::ExpiredSignature => e
          raise ExpiredTokenError, e.message
        rescue JWT::IncorrectAlgorithm => e
          raise InvalidAlgorithmError, e.message
        rescue JWT::InvalidAudError => e
          raise InvalidAudienceTokenError, e.message
        rescue JWT::ImmatureSignature => e
          # nbf is a property of the token, not the key — trying other keys
          # cannot rehabilitate a not-yet-valid token, so early-exit rather
          # than iterating through the remaining rotation keys.
          raise InvalidTokenError, e.message
        rescue JWT::VerificationError => e
          last_error = InvalidSignatureError.new(e.message)
          next
        rescue JWT::DecodeError => e
          last_error = InvalidTokenError.new(e.message)
          next
        end
      end

      raise last_error || InvalidTokenError.new("Token verification failed")
    end

    # Extracts the `aud` claim without signature verification, for use in
    # error messages only. Returns an array of strings; empty array if the
    # token is unparseable or has no aud claim. Never raises.
    def self.extract_unverified_audience(token)
      payload, = JWT.decode(token, nil, false)
      Array(payload&.dig("aud")).map(&:to_s)
    rescue StandardError
      []
    end

    private

    # Parses a previous_signing_keys entry into { kid:, key:, algorithm: }
    # Accepts either:
    #   - A PEM string or Pathname (uses current algorithm's key class)
    #   - A Hash with :key (PEM/Pathname) and :algorithm (e.g. :rs256, :es256)
    def self.parse_previous_key_entry(entry)
      if entry.is_a?(Hash)
        entry = entry.symbolize_keys
        alg = entry[:algorithm].to_s.upcase
        alg_config = SUPPORTED_ALGORITHMS[alg] || raise(ArgumentError, "Unsupported algorithm: #{alg}")
        key = parse_private_key(entry[:key], key_class: alg_config[:key_class])
      else
        alg = algorithm
        key = parse_private_key(entry)
      end

      vkey = key.is_a?(OpenSSL::PKey::EC) ? key : key.public_key
      kid = Digest::SHA256.hexdigest(key.public_to_pem)[0..7]
      { kid: kid, key: vkey, algorithm: alg }
    end

    def self.parse_private_key(key_source, key_class: nil)
      pem = key_source.is_a?(Pathname) ? File.read(key_source) : key_source
      key_class ||= algorithm_config[:key_class]

      key_class.new(pem)
    end

    def self.claim_resolver_keys
      resolvers = StandardId.config.oauth.claim_resolvers
      keys = Hash.try_convert(resolvers)&.keys
      keys.compact.map(&:to_sym).uniq.excluding(*RESERVED_JWT_KEYS, *BASE_SESSION_FIELDS)
    rescue StandardError
      []
    end
  end
end
