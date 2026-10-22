module StandardId
  # Notices about an account, sent to its address rather than to whoever made
  # the request.
  #
  # * #existing_account: sign-up was attempted for an address that already has
  #   an account, while `c.email_password.reveal_existing_accounts` is false
  #   (the API then answers as if the sign-up went ahead). The owner learns
  #   about it and how to get in; the requester learns nothing.
  #
  # Copy lives under `standard_id.account_notice_mailer.<action>.*` in
  # config/locales/en.yml; override any key in the host's locale files, or the
  # templates in app/views/standard_id/account_notice_mailer/.
  class AccountNoticeMailer < ApplicationMailer
    layout false

    helper_method :notice_copy

    # @param email [String]
    def existing_account
      @email = params[:email]

      mail(to: @email, from: StandardId.config.passwordless.mailer_from, subject: notice_copy(:subject))
    end

    # Copy for the current action, falling back to the gem's English (see
    # PasswordlessMailer#otp_copy).
    def notice_copy(key, default: nil, **options)
      scope = "standard_id.account_notice_mailer.#{action_name}"
      english = I18n.t(key, scope: scope, locale: :en, default: default, **options)
      I18n.t(key, scope: scope, default: english, **options)
    end
  end
end
