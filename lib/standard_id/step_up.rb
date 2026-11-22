module StandardId
  # Step-up (recent) authentication: before a sensitive action, ask a
  # signed-in account to prove its identity again unless it did so recently.
  # The shape follows Rodauth's confirm_password / password_grace_period.
  #
  # When the account last proved its identity is tracked on what authenticates
  # the request:
  #
  #   * a BrowserSession or DeviceSession row: Session#authenticated_at, set by
  #     an interactive sign-in and by a step-up, never by remember-me (a cookie
  #     is not a fresh proof) or by a refresh;
  #   * a bearer access token: the OIDC `auth_time` claim, minted from the
  #     same time (the authorize step's browser session for an authorization
  #     code, the original grant for a refresh, now for a step-up).
  #
  # A host guards an action with `require_recent_authentication!(within:)`
  # (WebAuthentication, ApiAuthentication). A stale web session is sent to the
  # step-up page; a stale bearer token gets RFC 9470's
  # `insufficient_user_authentication` challenge and steps up through the API.
  #
  # Re-proving identity takes a fresh one-time code from StandardId::Otp in its
  # own realm (`c.step_up.realm`, never the sign-in realm), sent to the
  # account's verified e-mail address or else its verified phone number, and,
  # when the account has a password and `c.step_up.require_password` is on, the
  # password too. The code is checked first, so each code buys at most one
  # password guess.
  #
  # Off by default (`c.step_up.enabled`): nothing is drawn, minted or written
  # differently until a host turns it on and calls the guard.
  module StepUp
    # The outcome of .start and .verify.
    #
    # - success?: true/false
    # - channel: "email" or "sms", where the code went (nil when there is none)
    # - error_code: on failure — :no_verified_identifier, :cooldown,
    #   :rate_limited, :invalid_request (from .start); :blank_code,
    #   :invalid_code, :max_attempts, :not_found, :server_error,
    #   :invalid_password (from .verify)
    # - error_message: human-readable, safe to show the account's owner
    Result = Data.define(:success?, :channel, :error_code, :error_message)

    ERROR_MESSAGES = {
      no_verified_identifier: "There is no verified e-mail address or phone number to send a code to",
      invalid_password: "The password is incorrect",
      invalid_code: "The code is invalid or has expired",
      blank_code: "Please enter the code",
      max_attempts: "Too many attempts. Please request a new code",
      not_found: "The code is invalid or has expired"
    }.freeze

    module_function

    def config
      StandardId.config.step_up
    end

    def enabled?
      config.enabled == true
    end

    def realm
      config.realm.presence || "step_up"
    end

    # The default `within:` for require_recent_authentication!.
    def max_age
      config.max_age.to_i.seconds
    end

    def session_column?
      StandardId::Session.column_names.include?("authenticated_at")
    rescue ActiveRecord::ActiveRecordError
      false
    end

    def refresh_token_column?
      StandardId::RefreshToken.column_names.include?("authenticated_at")
    rescue ActiveRecord::ActiveRecordError
      false
    end

    # What the guard needs before it can answer at all. A guard that silently
    # never passes (or always does) would be worse than one that says why.
    #
    # @raise [StandardId::ConfigurationError]
    def ensure_usable!
      unless enabled?
        raise StandardId::ConfigurationError,
          "require_recent_authentication! needs c.step_up.enabled = true (README, \"Step-up authentication\")"
      end
      return if session_column?

      raise StandardId::ConfigurationError,
        "c.step_up needs migration 20261123000000_add_authenticated_at_to_standard_id_sessions: " \
        "run bin/rails standard_id:install:migrations && bin/rails db:migrate"
    end

    # When +session+ last proved the account's identity, or nil: a session
    # row's #authenticated_at, or a decoded access token's `auth_time` claim.
    #
    # @return [Time, nil]
    def authenticated_at(session)
      return nil if session.nil?
      return session.authenticated_at if session.respond_to?(:authenticated_at)
      return nil unless session.respond_to?(:claims)

      auth_time = session.claims.to_h.with_indifferent_access[:auth_time]
      Time.at(Integer(auth_time)) if auth_time.present?
    rescue ArgumentError, TypeError
      nil
    end

    # Whether +session+ proved the account's identity within +within+ (a
    # Duration or seconds). A time in the future counts as not recent.
    def recent?(session, within: max_age)
      at = authenticated_at(session)
      return false if at.nil?

      now = Time.current
      at <= now && at >= now - within.to_i.seconds
    end

    # Records that +session+ (a session row) proved the account's identity at
    # +at+. A single UPDATE: nothing else on the row changes.
    def mark!(session, at: Time.current)
      return unless session.is_a?(StandardId::Session) && session.persisted? && session_column?

      session.update_columns(authenticated_at: at)
    end

    # Where a step-up code for +account+ goes: its verified e-mail identifier,
    # else its verified phone number, else nil.
    #
    # @return [Array(String, String), nil] `[channel, target]`
    def destination_for(account)
      identifiers = StandardId::Identifier.where(account_id: account.id).where.not(verified_at: nil).order(:created_at).to_a
      email = identifiers.find { |identifier| identifier.is_a?(StandardId::EmailIdentifier) }
      return ["email", email.value] if email

      phone = identifiers.find { |identifier| identifier.is_a?(StandardId::PhoneNumberIdentifier) }
      ["sms", phone.value] if phone
    end

    # Whether the step-up for +account+ asks for its password as well.
    def password_required?(account)
      config.require_password && password_credentials(account).any?
    end

    # Issues a step-up code to +account+'s verified e-mail or phone and
    # publishes STEP_UP_STARTED. A :cooldown failure means a code sent moments
    # ago is still usable; nothing new was sent.
    #
    # @return [Result]
    def start(account:, request: nil)
      channel, target = destination_for(account)
      return failure(account, :start, nil, :no_verified_identifier) if target.nil?

      issued = StandardId::Otp.issue(
        realm: realm,
        target: target,
        channel: channel.to_sym,
        request: request,
        delivery: config.delivery,
        metadata: { "account_id" => account.id.to_s }
      )
      unless issued.success?
        return Result.new(success?: false, channel: channel, error_code: issued.error_code, error_message: issued.error_message) if issued.error_code == :cooldown

        return failure(account, :start, channel, issued.error_code, issued.error_message)
      end

      StandardId::Events.publish(StandardId::Events::STEP_UP_STARTED, account: account, channel: channel)
      Result.new(success?: true, channel: channel, error_code: nil, error_message: nil)
    end

    # Checks a step-up: the code, then (when .password_required?) the
    # password. Publishes STEP_UP_SUCCEEDED or STEP_UP_FAILED. Marking the
    # session, or minting a fresh token, is the caller's job.
    #
    # @return [Result]
    def verify(account:, code:, password: nil, request: nil)
      channel, target = destination_for(account)
      return failure(account, :verify, nil, :no_verified_identifier) if target.nil?

      otp = StandardId::Otp.verify(realm: realm, target: target, channel: channel.to_sym, code: code.to_s.strip, request: request)
      return failure(account, :verify, channel, otp.error_code || :invalid_code) unless otp.success?
      # A code is only good for the account it was issued to.
      return failure(account, :verify, channel, :invalid_code) unless issued_to?(otp.challenge, account)

      methods = ["otp"]
      if password_required?(account)
        return failure(account, :verify, channel, :invalid_password) unless password_matches?(account, password)

        methods << "password"
      end

      StandardId::Events.publish(StandardId::Events::STEP_UP_SUCCEEDED, account: account, channel: channel, methods: methods)
      Result.new(success?: true, channel: channel, error_code: nil, error_message: nil)
    end

    def password_credentials(account)
      StandardId::PasswordCredential
        .joins(credential: :identifier)
        .where(standard_id_identifiers: { account_id: account.id })
    end

    def password_matches?(account, password)
      return false if password.blank?

      password_credentials(account).any? { |credential| credential.authenticate(password) }
    end

    # The bypass code (non-production E2E only) verifies with no challenge.
    def issued_to?(challenge, account)
      return true if challenge.nil?

      challenge.metadata.to_h["account_id"].to_s == account.id.to_s
    end

    def failure(account, stage, channel, error_code, error_message = nil)
      StandardId::Events.publish(
        StandardId::Events::STEP_UP_FAILED,
        account: account,
        stage: stage,
        channel: channel,
        error_code: error_code.to_s
      )
      Result.new(
        success?: false,
        channel: channel,
        error_code: error_code,
        error_message: ERROR_MESSAGES[error_code] || error_message || "Step-up failed"
      )
    end
  end
end
