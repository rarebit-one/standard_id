require "rails_helper"

RSpec.describe StandardId::Utils::CallableParameterFilter do
  describe ".filter" do
    let(:context) do
      {
        provider: "google",
        social_info: { email: "user@example.com" },
        tokens: { id_token: "token" },
        account: double("Account"),
        extra: "ignored"
      }
    end

    it "returns only the keys accepted by a proc" do
      callback = ->(provider:, social_info:) { }

      result = described_class.filter(callback, context)

      expect(result).to eq(provider: "google", social_info: { email: "user@example.com" })
    end

    it "returns the entire context when callable accepts keyrest" do
      callback = ->(**kwargs) { }

      result = described_class.filter(callback, context)

      expect(result).to eq(
        provider: "google",
        social_info: { email: "user@example.com" },
        tokens: { id_token: "token" },
        account: context[:account],
        extra: "ignored"
      )
    end

    it "handles objects responding to #parameters" do
      callable = Class.new do
        def self.parameters
          [[:keyreq, :tokens]]
        end

        def self.call(tokens:); end
      end

      result = described_class.filter(callable, context)

      expect(result).to eq(tokens: { id_token: "token" })
    end

    it "returns an empty hash when context is blank" do
      callback = ->(provider:) { }

      expect(described_class.filter(callback, nil)).to eq({})
    end
  end
end
