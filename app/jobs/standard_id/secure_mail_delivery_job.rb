module StandardId
  # Mailer delivery job that suppresses ActiveJob argument logging.
  #
  # The gem's mailers carry sensitive data in their params — the passwordless
  # OTP code (PasswordlessMailer) and the password-reset URL/token
  # (PasswordResetMailer). `deliver_later` serializes those params as the
  # delivery job's arguments, and ActiveJob's log subscriber prints job
  # arguments in plaintext on enqueue/perform — so the OTP/token would land in
  # the application logs (readable by anyone with log access).
  #
  # Setting `log_arguments = false` keeps the arguments out of the logs without
  # changing delivery behaviour. (The params still travel inside the serialized
  # job payload until the job runs — a far higher access bar than logs, and
  # short-lived — but they never reach the log stream.)
  class SecureMailDeliveryJob < ActionMailer::MailDeliveryJob
    self.log_arguments = false
  end
end
