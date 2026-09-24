require "rails_helper"
require "standard_id/testing"

# The dummy app bundles standard_id-apple, whose apple_client_id falls back to
# APPLE_CLIENT_ID when never assigned.
RSpec.describe StandardId::Testing::ConfigHelpers do
  include described_class

  let(:social) { StandardId.config.social }

  around do |example|
    saved = ENV.fetch("APPLE_CLIENT_ID", nil)
    original = social.to_h[:apple_client_id]
    was_assigned = social.assigned?(:apple_client_id)
    ENV.delete("APPLE_CLIENT_ID")
    social.delete(:apple_client_id)
    social.refresh_defaults!
    example.run
  ensure
    saved.nil? ? ENV.delete("APPLE_CLIENT_ID") : ENV["APPLE_CLIENT_ID"] = saved
    was_assigned ? social.apple_client_id = original : social.refresh_defaults!
  end

  it "enables a provider from ENV inside the block and restores ENV + config after" do
    expect(StandardId.social_provider_enabled?(:apple)).to be(false)

    with_provider_env("APPLE_CLIENT_ID" => "com.example.web") do
      expect(ENV["APPLE_CLIENT_ID"]).to eq("com.example.web")
      expect(social.apple_client_id).to eq("com.example.web")
      expect(StandardId.social_provider_enabled?(:apple)).to be(true)
    end

    expect(ENV.key?("APPLE_CLIENT_ID")).to be(false)
    expect(social.apple_client_id).to be_nil
    expect(StandardId.social_provider_enabled?(:apple)).to be(false)
  end

  it "restores even when the block raises, and unsets variables given nil" do
    ENV["APPLE_CLIENT_ID"] = "outer"
    social.refresh_defaults!

    expect {
      with_provider_env("APPLE_CLIENT_ID" => nil) do
        expect(social.apple_client_id).to be_nil
        raise "boom"
      end
    }.to raise_error("boom")

    expect(ENV["APPLE_CLIENT_ID"]).to eq("outer")
    expect(social.apple_client_id).to eq("outer")
  end

  it "does not override a field the host assigned explicitly" do
    social.apple_client_id = "explicit"

    with_provider_env("APPLE_CLIENT_ID" => "from-env") do
      expect(social.apple_client_id).to eq("explicit")
      expect(social.assigned?(:apple_client_id)).to be(true)
    end
  end

  it "is also callable on StandardId::Testing" do
    expect(StandardId::Testing.with_provider_env("APPLE_CLIENT_ID" => "x") { social.apple_client_id }).to eq("x")
  end
end
