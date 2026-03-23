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
end
