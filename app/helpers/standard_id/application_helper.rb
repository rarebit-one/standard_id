module StandardId
  module ApplicationHelper
    # The configured OTP code length, clamped to the engine's supported range
    # (4..10). Views use this so the verification-code input's `maxlength`
    # stays in sync with the length of codes the generator actually produces.
    def otp_code_length
      StandardId::Passwordless.otp_code_length
    end

    # The configured OTP resend cooldown, in seconds. The native login_verify
    # view uses this to drive a client-side "resend in Ns" countdown that mirrors
    # the server-side cooldown (passwordless.retry_delay, enforced in
    # BaseStrategy#enforce_retry_delay!). 0 or negative means no cooldown.
    def otp_retry_delay
      StandardId::Passwordless.retry_delay
    end
  end
end
