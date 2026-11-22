require "rails_helper"

# CREDENTIAL_PASSWORD_CHANGED on both reset paths, and the opt-in built-in
# notice (c.password.changed_notice_delivery = :built_in) it drives.
RSpec.describe "Password changed notice", type: :request do
  include ActiveJob::TestHelper

  let(:email) { "notice-#{SecureRandom.hex(4)}@example.com" }
  let(:old_password) { "OldPass1!xyz" }
  let(:new_password) { "NewPass1!abc" }
  let!(:account) { create_account_with_password(email: email, password: old_password) }

  def credential
    StandardId::PasswordCredential.find_by!(login: email)
  end

  def reset_on_web
    http_patch "/reset_password/confirm", params: {
      token: credential.generate_token_for(:password_reset), password: new_password, password_confirmation: new_password
    }
    expect(response).to redirect_to(standard_id_web.login_path)
  end

  def reset_over_api
    StandardId.config.email_password.enabled = true
    StandardId.config.email_password.reset_url = "https://app.example.com/password-reset?token={token}"
    http_post_json("/api/auth/password/reset", params: { token: credential.generate_token_for(:password_reset), password: new_password })
    expect(response).to have_http_status(:ok)
  end

  def changed_events
    events = []
    sub = StandardId::Events.subscribe(StandardId::Events::CREDENTIAL_PASSWORD_CHANGED) { |e| events << e.payload }
    yield
    events
  ensure
    StandardId::Events.unsubscribe(sub)
  end

  {
    "the web reset form" => :reset_on_web,
    "the email + password API reset" => :reset_over_api
  }.each do |path, reset|
    describe path do
      it "publishes CREDENTIAL_PASSWORD_CHANGED once, with reason :password_reset" do
        events = changed_events { send(reset) }

        expect(events.size).to eq(1)
        expect(events.first).to include(account: account, reason: :password_reset)
        expect(events.first[:credential].id).to eq(credential.id)
      end

      it "sends no notice by default" do
        expect { send(reset) }.not_to have_enqueued_mail(StandardId::AccountNoticeMailer, :password_changed)
      end

      it "emails the owner when c.password.changed_notice_delivery is :built_in" do
        StandardId.config.password.changed_notice_delivery = :built_in

        expect { perform_enqueued_jobs { send(reset) } }
          .to change { ActionMailer::Base.deliveries.count }.by(1)

        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq([email])
        expect(mail.subject).to eq(I18n.t("standard_id.account_notice_mailer.password_changed.subject"))
      end
    end
  end

  describe "with c.password.changed_notice_delivery = :built_in" do
    before { StandardId.config.password.changed_notice_delivery = :built_in }

    it "emails the owner when host code changes the password" do
      expect { credential.update!(password: new_password, password_confirmation: new_password) }
        .to have_enqueued_mail(StandardId::AccountNoticeMailer, :password_changed).with(params: { email: email }, args: [])
    end

    it "still emails the owner under events.publish_records = false" do
      StandardId.config.events.publish_records = false
      StandardId.config.events.publish_record_identifiers = false

      expect { reset_on_web }
        .to have_enqueued_mail(StandardId::AccountNoticeMailer, :password_changed).with(params: { email: email }, args: [])
    end

    it "sends nothing when only the digest is rewritten, as a rehash on login does" do
      expect {
        credential.update!(password_digest: BCrypt::Password.create(old_password, cost: BCrypt::Engine::MIN_COST + 1))
        credential.update_column(:password_digest, BCrypt::Password.create(old_password))
      }.not_to have_enqueued_mail(StandardId::AccountNoticeMailer, :password_changed)
    end

    it "sends nothing for a sign-in" do
      expect { http_post "/login", params: { login: { email: email, password: old_password }, redirect_uri: "/after" } }
        .not_to have_enqueued_mail(StandardId::AccountNoticeMailer, :password_changed)
      expect(response).to redirect_to("/after")
    end
  end
end
