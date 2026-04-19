require "rails_helper"

RSpec.describe StandardId::Engine do
  describe "filter_parameters initializer" do
    it "filters OAuth-sensitive parameters" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      %w[code_verifier code_challenge client_secret id_token refresh_token access_token state nonce authorization_code].each do |param|
        filtered = filter.filter(param => "secret_value")
        expect(filtered[param]).to eq("[FILTERED]"), "Expected #{param} to be filtered"
      end
    end
  end

  describe ".verify_host_cookie_encryption!" do
    let(:logger) { instance_double(Logger, warn: nil) }

    before do
      allow(Rails).to receive(:logger).and_return(logger)
    end

    it "warns when the host app has no secret_key_base" do
      app = double("App", secret_key_base: nil)
      expect(logger).to receive(:warn).with(a_string_including("secret_key_base"))

      described_class.verify_host_cookie_encryption!(app)
    end

    it "warns when secret_key_base is blank" do
      app = double("App", secret_key_base: "")
      expect(logger).to receive(:warn).with(a_string_including("secret_key_base"))

      described_class.verify_host_cookie_encryption!(app)
    end

    it "does not warn when secret_key_base is set" do
      app = double("App", secret_key_base: "x" * 64)
      expect(logger).not_to receive(:warn)

      described_class.verify_host_cookie_encryption!(app)
    end
  end
end
