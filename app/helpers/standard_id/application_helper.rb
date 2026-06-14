module StandardId
  module ApplicationHelper
    # The configured OTP code length, clamped to the engine's supported range
    # (4..10). Views use this so the verification-code input's `maxlength`
    # stays in sync with the length of codes the generator actually produces.
    def otp_code_length
      StandardId::Passwordless.otp_code_length
    end
  end
end
