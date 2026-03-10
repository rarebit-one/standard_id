require "rails_helper"

RSpec.describe StandardId::ApiAuthentication do
  describe "current_user alias" do
    context "when alias_current_user is false (default)" do
      let(:controller_class) do
        Class.new(ActionController::API) do
          include StandardId::ApiAuthentication
        end
      end

      it "does not define current_user" do
        expect(controller_class.method_defined?(:current_user)).to be false
      end
    end

    context "when alias_current_user is true" do
      around do |example|
        original_value = StandardId.config.alias_current_user
        StandardId.config.alias_current_user = true
        example.run
      ensure
        StandardId.config.alias_current_user = original_value
      end

      let(:controller_class) do
        Class.new(ActionController::API) do
          include StandardId::ApiAuthentication
        end
      end

      it "defines current_user" do
        expect(controller_class.method_defined?(:current_user)).to be true
      end

      it "returns the same value as current_account" do
        instance = controller_class.new
        account = double("Account")
        allow(instance).to receive(:current_account).and_return(account)

        expect(instance.current_user).to eq(account)
      end
    end
  end
end
