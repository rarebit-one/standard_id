require "rails_helper"
require "standard_id/testing/provider_examples"

# The dummy app bundles the real standard_id-google and standard_id-apple
# gems, so these run the helpers exactly as a host app's suite would.
RSpec.describe "StandardId::Testing provider examples" do
  it_behaves_like "a registered StandardId provider", :google
  it_behaves_like "a registered StandardId provider", :apple,
                  config_fields: %i[apple_client_id apple_mobile_client_id apple_private_key apple_key_id apple_team_id]

  describe "be_a_registered_standard_id_provider" do
    it "passes for a registered provider, defaulting to its config_schema fields" do
      expect(:google).to be_a_registered_standard_id_provider
      expect("apple").to be_a_registered_standard_id_provider.with_config_fields(:apple_client_id)
    end

    it "fails with a useful message for an unregistered provider" do
      expect { expect(:not_installed).to be_a_registered_standard_id_provider }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /:not_installed is not registered/)
    end

    it "fails when a named field is not declared" do
      expect { expect(:google).to be_a_registered_standard_id_provider.with_config_fields(:google_nope) }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /google_nope is not declared on the social config scope/)
    end
  end

  describe "ProviderExamples.round_trip" do
    it "restores a never-assigned field to unassigned, so ENV fallback still applies" do
      social = StandardId.config.social
      social.delete(:google_client_id)

      expect(StandardId::Testing::ProviderExamples.round_trip(:google_client_id, "probe")).to eq("probe")
      expect(social.key?(:google_client_id)).to be(false)
    end

    it "restores an assigned field to its previous value" do
      StandardId.config.social.google_client_id = "original"

      StandardId::Testing::ProviderExamples.round_trip(:google_client_id, "probe")

      expect(StandardId.config.social.google_client_id).to eq("original")
    end
  end
end
