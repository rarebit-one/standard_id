require "rails_helper"

RSpec.describe StandardId::NetworkWrapper do
  let(:transport_error) { Class.new(StandardError) }
  let(:circuit_open) { Class.new(StandardError) }

  it "runs the block directly when no wrapper is configured" do
    StandardId.config.network_wrapper = nil

    expect(described_class.run(provider: :google) { :response }).to eq(:response)
  end

  it "hands the provider to the wrapper as a Symbol and returns the block's result" do
    seen = []
    StandardId.config.network_wrapper = lambda do |provider:, &block|
      seen << provider
      block.call
    end

    expect(described_class.run(provider: "google") { :response }).to eq(:response)
    expect(seen).to eq([:google])
  end

  it "passes the block's arguments through the wrapper" do
    StandardId.config.network_wrapper = ->(&block) { block.call(:http) }

    expect(described_class.run(provider: :google) { |http| [http, :response] }).to eq([:http, :response])
  end

  context "with no wrapper" do
    before { StandardId.config.network_wrapper = nil }

    it "lets the block's own error through" do
      expect { described_class.run(provider: :google) { raise transport_error } }.to raise_error(transport_error)
    end
  end

  context "when the wrapper raises an error of its own without calling the block" do
    before do
      error = circuit_open
      StandardId.config.network_wrapper = ->(provider:, &_block) { raise error, "oauth_#{provider} is open" }
    end

    it "raises ProviderUnavailableError for the provider, with the wrapper's error as cause" do
      ran = false

      expect { described_class.run(provider: :google) { ran = true } }.to raise_error(StandardId::ProviderUnavailableError) { |error|
        expect(error.provider).to eq(:google)
        expect(error.message).to eq("Google is temporarily unavailable")
        expect(error.cause).to be_a(circuit_open)
        expect(error.cause.message).to eq("oauth_google is open")
      }
      expect(ran).to be(false)
    end

    it "is an OAuthError that renders as temporarily_unavailable / 503" do
      expect { described_class.run(provider: :google) { nil } }.to raise_error(StandardId::OAuthError) { |error|
        expect(error.oauth_error_code).to eq(:temporarily_unavailable)
        expect(error.http_status).to eq(:service_unavailable)
      }
    end
  end

  it "keeps an error the block raised, re-raised by the wrapper, as is" do
    seen = []
    StandardId.config.network_wrapper = lambda do |&block|
      block.call
    rescue StandardError => e
      seen << e.class
      raise
    end

    expect { described_class.run(provider: :google) { raise transport_error } }.to raise_error(transport_error)
    expect(seen).to eq([transport_error])
  end

  it "keeps the block's error when a retrying wrapper re-raises its last attempt" do
    StandardId.config.network_wrapper = lambda do |&block|
      attempts = 0
      begin
        attempts += 1
        block.call
      rescue StandardError
        retry if attempts < 2
        raise
      end
    end
    calls = 0

    expect {
      described_class.run(provider: :google) { raise transport_error, "attempt #{calls += 1}" }
    }.to raise_error(transport_error, "attempt 2")
  end

  it "treats a breaker that converts the block's error into its own as the wrapper's error" do
    error = circuit_open
    StandardId.config.network_wrapper = lambda do |&block|
      block.call
    rescue StandardError
      raise error, "tripped"
    end

    expect { described_class.run(provider: :apple) { raise transport_error } }.to raise_error(StandardId::ProviderUnavailableError) { |e|
      expect(e.provider).to eq(:apple)
      expect(e.cause).to be_a(circuit_open)
      expect(e.cause.cause).to be_a(transport_error)
    }
  end

  it "treats an error the wrapper raises after the block succeeded as the wrapper's error" do
    error = circuit_open
    StandardId.config.network_wrapper = lambda do |&block|
      block.call
      raise error, "tracer failed"
    end

    expect { described_class.run(provider: :google) { :response } }.to raise_error(StandardId::ProviderUnavailableError)
  end

  it "lets an OAuthError the wrapper raises on purpose through" do
    StandardId.config.network_wrapper = ->(&_block) { raise StandardId::InvalidRequestError, "refused by the host" }

    expect { described_class.run(provider: :google) { nil } }.to raise_error(StandardId::InvalidRequestError, "refused by the host")
  end

  it "does not wrap a ProviderUnavailableError from a nested call twice" do
    StandardId.config.network_wrapper = ->(&block) { block.call }
    inner = StandardId::ProviderUnavailableError.new(provider: :google)

    expect { described_class.run(provider: :standard_id) { raise inner } }.to raise_error(inner)
  end

  it "does not catch non-StandardError exceptions" do
    StandardId.config.network_wrapper = ->(&_block) { raise Interrupt }

    expect { described_class.run(provider: :google) { nil } }.to raise_error(Interrupt)
  end
end
