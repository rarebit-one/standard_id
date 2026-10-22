require "rails_helper"

RSpec.describe StandardId::AccountNoticeMailer, type: :mailer do
  describe "#existing_account" do
    let(:mail) { described_class.with(email: "owner@example.com").existing_account }

    it "goes to the address's owner, from the passwordless sender" do
      expect(mail.to).to eq(["owner@example.com"])
      expect(mail.from).to eq([StandardId.config.passwordless.mailer_from])
      expect(mail.subject).to eq(I18n.t("standard_id.account_notice_mailer.existing_account.subject"))
    end

    it "renders text and HTML parts with the copy, and nothing the requester sent" do
      intro = I18n.t("standard_id.account_notice_mailer.existing_account.intro")

      expect(mail.text_part.body.to_s).to include(intro)
      expect(mail.html_part.body.to_s).to include(ERB::Util.html_escape(intro))
    end

    it "uses the host's translation when one exists" do
      I18n.backend.store_translations(:en, standard_id: { account_notice_mailer: { existing_account: { subject: "Heads up" } } })

      expect(mail.subject).to eq("Heads up")
    ensure
      I18n.reload!
    end
  end
end
