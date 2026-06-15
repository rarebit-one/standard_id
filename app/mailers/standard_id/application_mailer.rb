module StandardId
  class ApplicationMailer < ActionMailer::Base
    # Use a delivery job that doesn't log its arguments — the gem's mailers pass
    # sensitive params (OTP code, password-reset token) that ActiveJob would
    # otherwise print in plaintext. Applies to all StandardId mailers.
    self.delivery_job = StandardId::SecureMailDeliveryJob

    default from: "from@example.com"
    layout "mailer"
  end
end
