require "rails_helper"

RSpec.describe StandardId::SecureMailDeliveryJob do
  it "disables ActiveJob argument logging (keeps OTP / reset token out of the logs)" do
    expect(described_class.log_arguments).to be(false)
  end

  it "subclasses ActionMailer's delivery job so delivery behaviour is unchanged" do
    expect(described_class.ancestors).to include(ActionMailer::MailDeliveryJob)
  end

  it "is wired as the delivery job for every StandardId mailer" do
    expect(StandardId::ApplicationMailer.delivery_job).to eq(described_class)
    expect(StandardId::PasswordlessMailer.delivery_job).to eq(described_class)
    expect(StandardId::PasswordResetMailer.delivery_job).to eq(described_class)
  end
end
