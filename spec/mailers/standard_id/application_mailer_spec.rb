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

  describe "StandardId.mailer_parent_class" do
    it "names the setting when the value is undefined" do
      allow(StandardId.config).to receive(:mailer_parent_class).and_return("ApplicationMailr")

      expect { StandardId.mailer_parent_class }
        .to raise_error(StandardId::ConfigurationError, /c\.mailer_parent_class = "ApplicationMailr"/)
    end

    it "names the setting when the value is a module, not a class" do
      allow(StandardId.config).to receive(:mailer_parent_class).and_return("Kernel")

      expect { StandardId.mailer_parent_class }
        .to raise_error(StandardId::ConfigurationError, /c\.mailer_parent_class = "Kernel"/)
    end

    it "names the setting when the class is not a mailer" do
      allow(StandardId.config).to receive(:mailer_parent_class).and_return("String")

      expect { StandardId.mailer_parent_class }
        .to raise_error(StandardId::ConfigurationError, /c\.mailer_parent_class = "String"/)
    end

    it "lets an error raised inside the parent's own file through unchanged" do
      allow(StandardId.config).to receive(:mailer_parent_class).and_return("BrokenHostMailer")
      allow(Object).to receive(:const_missing).and_call_original
      allow(Object).to receive(:const_missing).with(:BrokenHostMailer) { raise NameError.new("uninitialized constant Helperz", :Helperz) }

      expect { StandardId.mailer_parent_class }.to raise_error(NameError, /Helperz/)
    end
  end
end
