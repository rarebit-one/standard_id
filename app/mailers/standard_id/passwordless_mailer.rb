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

    # @param email [String]
    # @param otp_code [String]
    # @param expires_in_minutes [Integer, nil] defaults to passwordless.code_ttl
    def otp_email
      assign_otp_params
      subject = if StandardId.config.passwordless.assigned?(:mailer_subject)
        StandardId.config.passwordless.mailer_subject
      else
        I18n.t("standard_id.passwordless_mailer.otp_email.subject",
          default: StandardId.config.passwordless.mailer_subject)
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
        subject: I18n.t("standard_id.passwordless_mailer.verification_email.subject")
      )
    end

    private

    def assign_otp_params
      @otp_code = params[:otp_code]
      @email = params[:email]
      @expires_in_minutes = params[:expires_in_minutes] || (StandardId.config.passwordless.code_ttl / 60)
    end
  end
end
