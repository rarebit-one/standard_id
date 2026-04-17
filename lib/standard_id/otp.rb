require "standard_id/passwordless/base_strategy"
require "standard_id/passwordless/email_strategy"
require "standard_id/passwordless/sms_strategy"
require "standard_id/passwordless/verification_service"

module StandardId
  # Public OTP primitive — issue and verify one-time codes for any realm.
  #
  # Until now, OTP lifecycle logic lived inside the passwordless authentication
  # flow. Host apps that needed OTP for *other* purposes (contact verification,
  # widget confirmations, step-up challenges, etc.) had to call
  # +StandardId::CodeChallenge.create!+ directly and reimplement verification
  # — usually missing enumeration defenses, atomic attempt tracking, and
  # race-condition protection.
  #
  # +StandardId::Otp+ wraps the same hardened machinery used by the
  # passwordless login flow (+VerificationService+ + +BaseStrategy+) and
  # parameterizes it by realm so consumers can use OTP safely for anything.
  #
  # == Issue
  #
  #   result = StandardId::Otp.issue(
  #     realm: "widget_contact_verification",
  #     target: "user@example.com",
  #     channel: :email,
  #     request: request,
  #     delivery: :manual
  #   )
  #   result.code        # the raw 6-digit code (only when delivery: :manual)
  #   result.challenge   # StandardId::CodeChallenge record
  #
  # == Verify
  #
  #   result = StandardId::Otp.verify(
  #     realm: "widget_contact_verification",
  #     target: "user@example.com",
  #     channel: :email,
  #     code: params[:otp],
  #     request: request
  #   )
  #   result.success?    # boolean
  #   result.error_code  # :invalid_code | :expired | :max_attempts | :not_found | :blank_code | :server_error
  #   result.challenge   # consumed CodeChallenge on success, nil on failure (or bypass)
  #
  # == Delivery modes
  #
  # * +:built_in+ — uses the engine's bundled mailer
  #   (+StandardId::PasswordlessMailer+) when
  #   +StandardId.config.passwordless.delivery+ is +:built_in+. Works for
  #   +channel: :email+ only.
  # * +:custom+ — calls the configured +passwordless_email_sender+ or
  #   +passwordless_sms_sender+ callback.
  # * +:manual+ — skip delivery entirely; the raw +code+ is returned on the
  #   result so the caller can deliver it however they like. Useful for
  #   custom widget/embedded flows that want full control over the channel.
  module Otp
    VALID_CHANNELS  = %w[email sms].freeze
    VALID_DELIVERIES = %i[built_in custom manual].freeze
    DEFAULT_REALM    = "authentication".freeze

    # Result returned by .issue.
    #
    # - success?: true/false
    # - challenge: the created CodeChallenge (nil on failure)
    # - code: raw OTP code — only populated when delivery: :manual
    # - error_code: machine-readable symbol on failure
    # - error_message: human-readable message on failure
    IssueResult = Data.define(:success?, :challenge, :code, :error_code, :error_message) do
      # Back-compat alias so callers can write +result.error+ like the
      # VerificationService Result.
      def error = error_message
    end

    class << self
      # Issue a new OTP in the given realm.
      #
      # @param realm [String] Free-form realm name that partitions challenges
      #   by purpose (e.g. "authentication", "widget_contact_verification").
      # @param target [String] The recipient identifier — email address or
      #   phone number, depending on +channel+.
      # @param channel [Symbol, String] :email or :sms.
      # @param request [ActionDispatch::Request, nil] Current request. Used
      #   to stamp ip_address/user_agent on the challenge. Optional — when
      #   nil, a minimal null-object is used.
      # @param code_length [Integer, nil] Number of digits (4..10). Defaults
      #   to 6.
      # @param expires_in [Integer, ActiveSupport::Duration, nil] TTL.
      #   Defaults to +StandardId.config.passwordless.code_ttl+ seconds.
      # @param metadata [Hash] Extra metadata to stamp on the challenge.
      # @param delivery [Symbol] :built_in, :custom, or :manual (see above).
      # @return [IssueResult]
      def issue(realm:, target:, channel: :email, request: nil, code_length: nil, expires_in: nil, metadata: {}, delivery: :built_in)
        channel_s  = channel.to_s
        realm_s    = realm.to_s
        delivery_s = delivery.to_sym

        unless VALID_CHANNELS.include?(channel_s)
          raise StandardId::InvalidRequestError, "Unsupported channel: #{channel.inspect} (must be :email or :sms)"
        end
        unless VALID_DELIVERIES.include?(delivery_s)
          raise StandardId::InvalidRequestError, "Unsupported delivery: #{delivery.inspect} (must be :built_in, :custom, or :manual)"
        end
        if realm_s.blank?
          return failure_issue_result(:invalid_request, "realm: is required")
        end
        if target.to_s.strip.blank?
          return failure_issue_result(:invalid_request, "target: is required")
        end

        strategy = build_strategy(channel_s, request, realm: realm_s)

        begin
          challenge = strategy.start!(
            username: target,
            code_length: code_length,
            expires_in: normalize_expires_in(expires_in),
            metadata: metadata,
            skip_sender: delivery_s == :manual
          )
        rescue StandardId::InvalidRequestError => e
          # Validation failures from the strategy (invalid email/phone format,
          # custom username_validator rejections, etc.) are surfaced as a
          # failed result instead of propagating, so callers can handle them
          # like any other OTP outcome.
          return failure_issue_result(:invalid_request, e.message)
        end

        IssueResult.new(
          success?: true,
          challenge: challenge,
          code: delivery_s == :manual ? challenge.code : nil,
          error_code: nil,
          error_message: nil
        )
      end

      # Verify a previously issued OTP.
      #
      # Delegates to +VerificationService+, which already handles:
      # - Constant-time compare even when no challenge exists (enum defense)
      # - Atomic failed-attempt tracking (PR #165)
      # - Transactional lock to prevent concurrent reuse (PR #169)
      #
      # When +StandardId.config.passwordless.bypass_code+ is set (and we are
      # not in production) and +code+ matches it, verification succeeds
      # without looking up a challenge. This is intentionally realm-scoped:
      # any realm accepts the bypass code. Bypass is intended for E2E
      # testing only. Never set +bypass_code+ in production.
      #
      # @param realm [String] The realm the challenge was issued in.
      # @param target [String] Recipient identifier.
      # @param channel [Symbol, String] :email or :sms.
      # @param code [String] The submitted code.
      # @param request [ActionDispatch::Request, nil]
      # @return [VerificationService::Result] See VerificationService docs.
      def verify(realm:, target:, code:, channel: :email, request: nil)
        channel_s = channel.to_s
        realm_s   = realm.to_s

        unless VALID_CHANNELS.include?(channel_s)
          raise StandardId::InvalidRequestError, "Unsupported channel: #{channel.inspect} (must be :email or :sms)"
        end
        if realm_s.blank?
          raise StandardId::InvalidRequestError, "realm: is required"
        end

        req = request || NullRequest.new

        # For the "authentication" realm, retain legacy behavior: resolve
        # and return an Account so existing callers (passwordless login)
        # keep working. For any other realm, skip account resolution —
        # callers of Otp.verify are using the primitive for non-auth
        # flows (contact verification, widget confirms, step-up, etc.)
        # and should not need an Account to exist.
        resolve_account = realm_s == DEFAULT_REALM

        kwargs = {
          code: code,
          request: req,
          realm: realm_s,
          resolve_account: resolve_account
        }
        if channel_s == "email"
          kwargs[:email] = target
        else
          kwargs[:phone] = target
        end

        StandardId::Passwordless::VerificationService.verify(**kwargs)
      end

      private

      def build_strategy(channel, request, realm:)
        req = request || NullRequest.new
        case channel
        when "email" then StandardId::Passwordless::EmailStrategy.new(req, realm: realm)
        when "sms"   then StandardId::Passwordless::SmsStrategy.new(req, realm: realm)
        end
      end

      def normalize_expires_in(value)
        return nil if value.nil?
        return value if value.is_a?(ActiveSupport::Duration)
        value.to_i.seconds
      end

      def failure_issue_result(error_code, error_message)
        IssueResult.new(
          success?: false,
          challenge: nil,
          code: nil,
          error_code: error_code,
          error_message: error_message
        )
      end
    end

    # Minimal stand-in used when no request is available (e.g. jobs, tests).
    # BaseStrategy reads +remote_ip+, +user_agent+, and +params+.
    class NullRequest
      def remote_ip = nil
      def user_agent = nil
      def params = {}
    end
  end
end
