require "rails_helper"

RSpec.describe StandardId::ApplicationMailer do
  it "inherits from ActionMailer::Base by default" do
    expect(described_class.superclass).to eq(ActionMailer::Base)
  end

  context "with mailer_parent_class set" do
    # The parent is resolved when the class body loads, so load a fresh copy
    # of the file under a stubbed config and put the original back afterwards.
    before do
      @original = StandardId.send(:remove_const, :ApplicationMailer)
      stub_const("HostMailer", Class.new(ActionMailer::Base) { layout "host_mailer" })
      allow(StandardId.config).to receive(:mailer_parent_class).and_return("HostMailer")
      load StandardId::Engine.root.join("app/mailers/standard_id/application_mailer.rb").to_s
    end

    after do
      StandardId.send(:remove_const, :ApplicationMailer) if StandardId.const_defined?(:ApplicationMailer, false)
      StandardId.const_set(:ApplicationMailer, @original)
    end

    it "inherits from the configured class and keeps its layout" do
      mailer = StandardId::ApplicationMailer

      expect(mailer.superclass).to eq(HostMailer)
      expect(mailer._layout).to eq("host_mailer")
      expect(mailer.delivery_job).to eq(StandardId::SecureMailDeliveryJob)
    end
  end
end
