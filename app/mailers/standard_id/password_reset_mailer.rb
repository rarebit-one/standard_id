module StandardId
  class PasswordResetMailer < ApplicationMailer
    layout false

    def reset_email
      @reset_url = params[:reset_url]
      @email = params[:email]

      mail(
        to: @email,
        from: StandardId.config.reset_password.mailer_from,
        subject: StandardId.config.reset_password.mailer_subject
      )
    end
  end
end
