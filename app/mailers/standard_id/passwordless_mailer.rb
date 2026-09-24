module StandardId
  # Built-in OTP emails, sent by Events::Subscribers::PasswordlessDeliverySubscriber
  # when `c.passwordless.delivery = :built_in`.
  #
  # * #otp_email — the sign-in code (realm "authentication").
  # * #verification_email — every other realm: WebEngine verify_email/start
  #   (realm "verification") and `Otp.issue(realm: ...)` for contact
  #   verification, step-up and the like. It must not tell the recipient the
  #   code is for signing in.
  #
  # Copy lives under `standard_id.passwordless_mailer.<action>.*` in
  # config/locales/en.yml; override any key in the host's locale files, or
  # override the templates in app/views/standard_id/passwordless_mailer/.
  # `c.passwordless.mailer_subject`, when assigned, still sets the sign-in
  # subject (it wins over the i18n key).
  class PasswordlessMailer < ApplicationMailer
    layout false

    helper_method :otp_copy

    # @param email [String]
    # @param otp_code [String]
    # @param expires_in_minutes [Integer, nil] defaults to passwordless.code_ttl
    def otp_email
      assign_otp_params
      subject = if StandardId.config.passwordless.assigned?(:mailer_subject)
        StandardId.config.passwordless.mailer_subject
      else
        otp_copy(:subject, default: StandardId.config.passwordless.mailer_subject)
      end

      mail(to: @email, from: StandardId.config.passwordless.mailer_from, subject: subject)
    end

    # @param email [String]
    # @param otp_code [String]
    # @param realm [String, nil] the OTP realm, available to overriding templates
    # @param expires_in_minutes [Integer, nil] defaults to passwordless.code_ttl
    def verification_email
      assign_otp_params
      @realm = params[:realm]

      mail(
        to: @email,
        from: StandardId.config.passwordless.mailer_from,
        subject: otp_copy(:subject)
      )
    end

    # Copy for the current action from
    # standard_id.passwordless_mailer.<action>.<key>, in I18n.locale. Falls
    # back to the gem's English copy when the host has no translation for
    # that locale (the gem ships only `en`, and a host need not enable
    # I18n fallbacks), so a zh-SG request never renders "translation missing".
    #
    # @param key [Symbol, String]
    # @param default [String, nil] final fallback when even `en` has no key
    def otp_copy(key, default: nil, **options)
      scope = "standard_id.passwordless_mailer.#{action_name}"
      english = I18n.t(key, scope: scope, locale: :en, default: default, **options)
      I18n.t(key, scope: scope, default: english, **options)
    end

    private

    def assign_otp_params
      @otp_code = params[:otp_code]
      @email = params[:email]
      @expires_in_minutes = params[:expires_in_minutes] || (StandardId.config.passwordless.code_ttl / 60)
    end
  end
end
