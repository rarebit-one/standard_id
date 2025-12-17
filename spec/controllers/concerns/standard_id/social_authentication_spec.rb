require "rails_helper"

RSpec.describe StandardId::SocialAuthentication do
  let(:dummy_class) do
    Class.new do
      include StandardId::SocialAuthentication
    end
  end

  let(:instance) { dummy_class.new }
  let(:social_info) { { email: "user@example.com" } }
  let(:provider_tokens) { { id_token: "id-token" } }
  let(:account) { double("Account") }

  describe "#run_social_callback" do
    it "passes only the keys accepted by the callback" do
      event_received = nil
      StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_COMPLETED) do |event|
        event_received = event
      end

      instance.send(
        :run_social_callback,
        provider: "google",
        social_info: social_info,
        provider_tokens: provider_tokens,
        account: account
      )

      expect(event_received).to be_present
      expect(event_received[:account]).to eq(account)
      expect(event_received[:provider]).to eq("google")
      expect(event_received[:social_info]).to match(social_info)
      expect(event_received[:tokens]).to match(provider_tokens)
    end
  end
end
