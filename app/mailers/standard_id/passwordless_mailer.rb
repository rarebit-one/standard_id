module StandardId
  class PasswordlessMailer < ApplicationMailer
    def otp_email
      @otp_code = params[:otp_code]
      @email = params[:email]

      mail(
        to: @email,
        from: StandardId.config.passwordless.mailer_from,
        subject: StandardId.config.passwordless.mailer_subject
      )
    end
  end
end
