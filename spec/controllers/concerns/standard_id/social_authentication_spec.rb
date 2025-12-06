require "rails_helper"

RSpec.describe StandardId::SocialAuthentication do
  let(:dummy_class) do
    Class.new(ActionController::Base) do
      include StandardId::SocialAuthentication
    end
  end

  let(:instance) { dummy_class.new }
  let(:social_info) { { email: "user@example.com" } }
  let(:provider_tokens) { { id_token: "id-token" } }
  let(:account) { double("Account") }

  around do |example|
    original_callback = StandardId.config.social_callback
    example.run
  ensure
    StandardId.config.social_callback = original_callback
  end

  describe "#run_social_callback" do
    it "passes only the keys accepted by the callback" do
      received = nil
      StandardId.config.social_callback = lambda do |provider:, social_info:|
        received = { provider: provider, social_info: social_info }
      end

      instance.send(
        :run_social_callback,
        provider: "google",
        social_info: social_info,
        provider_tokens: provider_tokens,
        account: account
      )

      expect(received).to eq(provider: "google", social_info: social_info)
    end

    it "passes the full payload when the callback accepts keyrest" do
      received = nil
      StandardId.config.social_callback = ->(**payload) { received = payload }

      instance.send(
        :run_social_callback,
        provider: "apple",
        social_info: social_info,
        provider_tokens: provider_tokens,
        account: account
      )

      expect(received.keys).to contain_exactly(:provider, :social_info, :tokens, :account)
    end
  end
end
