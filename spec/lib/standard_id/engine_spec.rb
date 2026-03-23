require "rails_helper"

RSpec.describe StandardId::Engine do
  describe "filter_parameters initializer" do
    it "adds OAuth-sensitive parameters to filter_parameters" do
      expected_params = %i[
        code_verifier code_challenge client_secret
        id_token refresh_token access_token
        state nonce authorization_code
      ]

      expected_params.each do |param|
        expect(Rails.application.config.filter_parameters).to include(param)
      end
    end
  end
end
