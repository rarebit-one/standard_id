require "spec_helper"
require "standard_config"
require "active_support/core_ext/string/inflections"

RSpec.describe StandardConfig::Config do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "initializes with nil values or empty arrays as appropriate" do
      expect(config.account_class_name).to be_nil
      expect(config.cache_store).to be_nil
      expect(config.logger).to be_nil
      expect(config.allowed_post_logout_redirect_uris).to eq([])
      expect(config.web_layout).to be_nil
    end
  end

  describe "#account_class" do
    it "returns the constantized class when the name is valid" do
      stub_const("Account", Class.new)
      config.account_class_name = "Account"
      expect(config.account_class).to eq(Account)
    end

    it "raises a NameError with a helpful message when the class is missing" do
      config.account_class_name = "MissingAccountClass"
      expect { config.account_class }
        .to raise_error(NameError, /Could not find account class: MissingAccountClass/)
    end
  end
end
