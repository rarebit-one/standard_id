module StandardId
  # Inherits from `StandardId.config.mailer_parent_class` (ActionMailer::Base by
  # default). The class is resolved when this file loads, which is after the
  # host's initializers have run.
  class ApplicationMailer < StandardId.config.mailer_parent_class.constantize
    # Use a delivery job that doesn't log its arguments — the gem's mailers pass
    # sensitive params (OTP code, password-reset token) that ActiveJob would
    # otherwise print in plaintext. Applies to all StandardId mailers.
    self.delivery_job = StandardId::SecureMailDeliveryJob

    # A host parent brings its own defaults and layout; keep the gem's only on
    # the bare ActionMailer::Base.
    if superclass == ActionMailer::Base
      default from: "from@example.com"
      layout "mailer"
    end
  end
end
