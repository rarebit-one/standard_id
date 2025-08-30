require "rails_helper"

RSpec.describe StandardId::Config do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "initializes with nil values" do
      expect(config.account_class_name).to be_nil
      expect(config.cache_store).to be_nil
      expect(config.logger).to be_nil
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

  describe "integration via StandardId.configure" do
    it "sets and reads values on the global config" do
      begin
        StandardId.configure do |c|
          c.account_class_name = "User"
          c.cache_store = :my_cache
          c.logger = :my_logger
        end

        expect(StandardId.config.account_class_name).to eq("User")
        expect(StandardId.config.cache_store).to eq(:my_cache)
        expect(StandardId.config.logger).to eq(:my_logger)
      ensure
        # reset the global config to avoid leakage between examples
        StandardId.instance_variable_set(:@config, nil)
      end
    end
  end
end
