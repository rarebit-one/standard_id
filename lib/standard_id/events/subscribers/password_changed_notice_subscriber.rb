module StandardId
  module Events
    module Subscribers
      # Emails the owner when their password is changed or reset, while
      # c.password.changed_notice_delivery is :built_in. Sent to the
      # credential's e-mail identifier; a credential behind a username or phone
      # identifier gets nothing. Under events.publish_records = false the
      # payload carries no records, so the credential is loaded from
      # +credential_id+.
      class PasswordChangedNoticeSubscriber < Base
        subscribe_to StandardId::Events::CREDENTIAL_PASSWORD_CHANGED

        def call(event)
          return unless built_in_delivery?

          identifier = password_credential(event)&.credential&.identifier
          return unless identifier.is_a?(StandardId::EmailIdentifier) && identifier.value.present?

          StandardId::AccountNoticeMailer.with(email: identifier.value).password_changed.deliver_later
        end

        def handle_error(error, event)
          StandardId.logger.error(
            "[StandardId::PasswordChangedNotice] Failed to deliver password changed notice " \
            "for password credential #{event[:credential_id]}: #{error.message}"
          )
        end

        private

        def password_credential(event)
          event[:credential] ||
            (event[:credential_id] && StandardId::PasswordCredential.includes(credential: :identifier).find_by(id: event[:credential_id]))
        end

        def built_in_delivery?
          StandardId.config.password.changed_notice_delivery == :built_in
        end
      end
    end
  end
end
