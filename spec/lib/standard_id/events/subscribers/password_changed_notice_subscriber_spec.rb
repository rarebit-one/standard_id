require "rails_helper"

RSpec.describe StandardId::Events::Subscribers::PasswordChangedNoticeSubscriber do
  include ActiveJob::TestHelper

  let(:account) { Account.create!(name: "Owner", email: "owner@example.com") }
  let(:subscriber) { described_class.new }

  def event_for(identifier)
    credential = StandardId::PasswordCredential.create!(login: identifier.value, password: "Password1!").tap do |c|
      StandardId::Credential.create!(credentialable: c, identifier: identifier)
    end
    StandardId::Events::Event.new(
      name: "standard_id.credential.password.changed",
      payload: { event_type: "credential.password.changed", credential: credential, account: account, reason: :changed }
    )
  end

  let(:email_event) { event_for(StandardId::EmailIdentifier.create!(account: account, value: "owner@example.com")) }

  it "subscribes to CREDENTIAL_PASSWORD_CHANGED" do
    expect(described_class.subscribed_events).to eq([StandardId::Events::CREDENTIAL_PASSWORD_CHANGED])
  end

  it "sends nothing while changed_notice_delivery is :custom (the default)" do
    expect(StandardId.config.password.changed_notice_delivery).to eq(:custom)
    expect { subscriber.call(email_event) }.not_to have_enqueued_mail(StandardId::AccountNoticeMailer, :password_changed)
  end

  context "when changed_notice_delivery is :built_in" do
    before { StandardId.config.password.changed_notice_delivery = :built_in }

    it "mails the credential's e-mail identifier" do
      expect { subscriber.call(email_event) }
        .to have_enqueued_mail(StandardId::AccountNoticeMailer, :password_changed).with(params: { email: "owner@example.com" }, args: [])
    end

    it "loads the credential from credential_id when the payload carries no records" do
      credential = email_event[:credential]
      event = StandardId::Events::Event.new(
        name: "standard_id.credential.password.changed",
        payload: { event_type: "credential.password.changed", credential_id: credential.id, reason: :changed }
      )

      expect { subscriber.call(event) }
        .to have_enqueued_mail(StandardId::AccountNoticeMailer, :password_changed).with(params: { email: "owner@example.com" }, args: [])
    end

    it "sends nothing for a credential behind a username identifier" do
      event = event_for(StandardId::UsernameIdentifier.create!(account: account, value: "owner"))

      expect { subscriber.call(event) }.not_to have_enqueued_mail(StandardId::AccountNoticeMailer, :password_changed)
    end

    it "logs instead of raising when delivery fails" do
      logger = instance_double(Logger, error: nil)
      allow(StandardId).to receive(:logger).and_return(logger)
      allow(StandardId::AccountNoticeMailer).to receive(:with).and_raise("smtp down")

      expect { subscriber.handle(email_event) }.not_to raise_error
      expect(logger).to have_received(:error).with(/Failed to deliver password changed notice.*smtp down/)
    end
  end
end
