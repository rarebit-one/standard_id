require "rails_helper"

RSpec.describe StandardId::NetworkWrapper do
  include ActiveSupport::Testing::TimeHelpers

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

  it "treats a breaker that raises a copy of the block's error (not the same object) as the wrapper's error" do
    StandardId.config.network_wrapper = lambda do |&block|
      block.call
    rescue StandardError => e
      raise e.class, e.message
    end

    expect { described_class.run(provider: :google) { raise transport_error, "connect failed" } }
      .to raise_error(StandardId::ProviderUnavailableError) { |e|
        expect(e.cause).to be_a(transport_error)
        expect(e.cause.message).to eq("connect failed")
      }
  end

  it "re-raises an error the wrapper raises after the block returned unchanged (the request went through)" do
    tracer_failed = Class.new(StandardError)
    StandardId.config.network_wrapper = lambda do |&block|
      block.call
      raise tracer_failed, "span export failed"
    end
    ran = 0

    expect { described_class.run(provider: :apple) { ran += 1 } }.to raise_error(tracer_failed, "span export failed")
    expect(ran).to eq(1)
  end

  context "with a programming error in the wrapper, before the block runs" do
    {
      "NoMethodError" => [NoMethodError, -> { nil.circuit_for(:google) }],
      "NameError for an undefined constant" => [NameError, -> { Object.const_get(:StandardCircuitNotLoaded) }],
      "ArgumentError" => [ArgumentError, -> { Integer("not a number") }],
      "TypeError" => [TypeError, -> { 1 + "1" }]
    }.each do |label, (klass, mistake)|
      it "re-raises a #{label} unchanged, so it reaches the error tracker" do
        StandardId.config.network_wrapper = lambda do |&block|
          mistake.call
          block.call
        end
        ran = false

        expect { described_class.run(provider: :google) { ran = true } }.to raise_error(klass) { |error|
          expect(error).not_to be_a(StandardId::ProviderUnavailableError)
        }
        expect(ran).to be(false)
      end
    end

    it "lists them in a frozen PROGRAMMING_ERRORS" do
      expect(described_class::PROGRAMMING_ERRORS).to eq([NameError, TypeError, ArgumentError])
      expect(described_class::PROGRAMMING_ERRORS).to be_frozen
    end
  end

  context "with a retrying wrapper, the last call of the block decides" do
    it "re-raises an error raised after a retry succeeded unchanged" do
      tracer_failed = Class.new(StandardError)
      StandardId.config.network_wrapper = lambda do |&block|
        attempts = 0
        begin
          attempts += 1
          block.call
        rescue StandardError
          retry if attempts < 2
          raise
        end
        raise tracer_failed, "post-call"
      end
      calls = 0
      error = transport_error

      expect {
        described_class.run(provider: :google) { (calls += 1) == 1 ? raise(error) : :response }
      }.to raise_error(tracer_failed, "post-call")
      expect(calls).to eq(2)
    end

    it "converts the wrapper's own error when the block succeeded once and then failed on the retry" do
      error = circuit_open
      StandardId.config.network_wrapper = lambda do |&block|
        block.call
        begin
          block.call
        rescue StandardError
          raise error, "gave up"
        end
      end
      calls = 0
      failure = transport_error

      expect {
        described_class.run(provider: :google) { (calls += 1) == 1 ? :response : raise(failure) }
      }.to raise_error(StandardId::ProviderUnavailableError) { |e| expect(e.cause).to be_a(circuit_open) }
    end

    it "passes the retry's own error through when the wrapper re-raises it" do
      StandardId.config.network_wrapper = lambda do |&block|
        block.call
        block.call
      end
      calls = 0
      failure = transport_error

      expect {
        described_class.run(provider: :google) { (calls += 1) == 1 ? :response : raise(failure, "second") }
      }.to raise_error(transport_error, "second")
    end
  end

  describe "the default provider's message" do
    it "reads like no provider for HttpClient's :standard_id, and keeps the provider it was given" do
      error = StandardId::ProviderUnavailableError.new(provider: StandardId::HttpClient::DEFAULT_PROVIDER)

      expect(error.message).to eq("The provider is temporarily unavailable")
      expect(error.provider).to eq(:standard_id)
    end

    it "treats HttpClient's default provider as unnamed" do
      expect(StandardId::ProviderUnavailableError::UNNAMED_PROVIDERS).to include(StandardId::HttpClient::DEFAULT_PROVIDER)
    end

    it "builds without HttpClient, which plugin specs replace with stand-ins" do
      hide_const("StandardId::HttpClient")

      expect(StandardId::ProviderUnavailableError.new(provider: :apple).message).to eq("Apple is temporarily unavailable")
    end

    it "reads like no provider for nil" do
      expect(StandardId::ProviderUnavailableError.new.message).to eq("The provider is temporarily unavailable")
    end

    it "still hands the wrapper provider: :standard_id" do
      seen = []
      StandardId.config.network_wrapper = lambda do |provider:, &_block|
        seen << provider
        raise "circuit open"
      end

      expect { described_class.run(provider: StandardId::HttpClient::DEFAULT_PROVIDER) { nil } }
        .to raise_error(StandardId::ProviderUnavailableError, "The provider is temporarily unavailable")
      expect(seen).to eq([:standard_id])
    end
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

  describe "config.network_wrapper_passthrough_errors" do
    # A misconfiguration the host's breaker reports as its own error, such as
    # StandardCircuit::UnknownCircuit for a circuit that was never registered.
    let(:unknown_circuit) { Class.new(StandardError) }

    def wrapper_raising(error, message = "no circuit named oauth_google")
      StandardId.config.network_wrapper = ->(provider:, &_block) { raise error, message }
    end

    it "defaults to an empty list" do
      expect(StandardId.config.network_wrapper_passthrough_errors).to eq([])
    end

    it "re-raises a wrapper error listed as a class unchanged" do
      StandardId.config.network_wrapper_passthrough_errors = [unknown_circuit]
      wrapper_raising(unknown_circuit)
      ran = false

      expect { described_class.run(provider: :google) { ran = true } }
        .to raise_error(unknown_circuit, "no circuit named oauth_google") { |error|
          expect(error).not_to be_a(StandardId::ProviderUnavailableError)
        }
      expect(ran).to be(false)
    end

    it "re-raises a wrapper error listed by class name unchanged" do
      stub_const("FakeCircuit::UnknownCircuit", unknown_circuit)
      StandardId.config.network_wrapper_passthrough_errors = ["FakeCircuit::UnknownCircuit"]
      wrapper_raising(unknown_circuit)

      expect { described_class.run(provider: :google) { nil } }.to raise_error(unknown_circuit)
    end

    it "matches subclasses of a listed class" do
      subclass = Class.new(unknown_circuit)
      StandardId.config.network_wrapper_passthrough_errors = [unknown_circuit]
      wrapper_raising(subclass)

      expect { described_class.run(provider: :google) { nil } }.to raise_error(subclass)
    end

    it "ignores a class name that resolves to nothing and still converts the error" do
      StandardId.config.network_wrapper_passthrough_errors = ["CircuitGemNotLoaded::UnknownCircuit", unknown_circuit]
      wrapper_raising(circuit_open, "oauth_google is open")

      expect { described_class.run(provider: :google) { nil } }
        .to raise_error(StandardId::ProviderUnavailableError) { |e| expect(e.cause).to be_a(circuit_open) }
    end

    it "still passes a listed error through when an unknown name precedes it" do
      StandardId.config.network_wrapper_passthrough_errors = ["CircuitGemNotLoaded::UnknownCircuit", unknown_circuit]
      wrapper_raising(unknown_circuit)

      expect { described_class.run(provider: :google) { nil } }.to raise_error(unknown_circuit)
    end

    it "converts an unlisted wrapper error as before" do
      StandardId.config.network_wrapper_passthrough_errors = [unknown_circuit]
      wrapper_raising(circuit_open, "oauth_google is open")

      expect { described_class.run(provider: :google) { nil } }
        .to raise_error(StandardId::ProviderUnavailableError) { |e| expect(e.cause).to be_a(circuit_open) }
    end

    it "leaves the block's own errors as they are, listed or not" do
      StandardId.config.network_wrapper_passthrough_errors = [unknown_circuit]
      StandardId.config.network_wrapper = ->(&block) { block.call }

      expect { described_class.run(provider: :google) { raise transport_error, "connect failed" } }
        .to raise_error(transport_error, "connect failed")
      listed = unknown_circuit
      expect { described_class.run(provider: :google) { raise listed, "from the request" } }
        .to raise_error(unknown_circuit, "from the request")
    end
  end

  describe "retry_after on ProviderUnavailableError" do
    let(:red_light) do
      Class.new(StandardError) do
        def initialize(retry_after: nil, cool_off_time: nil)
          super("light is red")
          @retry_after = retry_after
          @cool_off_time = cool_off_time
        end

        attr_reader :retry_after, :cool_off_time
      end
    end

    def refused_with(error)
      StandardId.config.network_wrapper = ->(&_block) { raise error }
      described_class.run(provider: :google) { nil }
    rescue StandardId::ProviderUnavailableError => e
      e
    end

    it "uses the seconds until a retry_after Time, rounded up" do
      freeze_time do
        error = refused_with(red_light.new(retry_after: Time.now + 29.2, cool_off_time: 60))

        expect(error.retry_after).to eq(30)
      end
    end

    it "gives no retry_after for a retry_after Time already past, ignoring cool_off_time" do
      error = refused_with(red_light.new(retry_after: Time.now - 5, cool_off_time: 60))

      expect(error.retry_after).to be_nil
    end

    it "uses a numeric retry_after, rounded up" do
      expect(refused_with(red_light.new(retry_after: 12.1)).retry_after).to eq(13)
      expect(refused_with(red_light.new(retry_after: 45)).retry_after).to eq(45)
    end

    it "gives no retry_after for a zero or negative numeric retry_after" do
      expect(refused_with(red_light.new(retry_after: 0, cool_off_time: 60)).retry_after).to be_nil
      expect(refused_with(red_light.new(retry_after: -3)).retry_after).to be_nil
    end

    it "falls back to cool_off_time when retry_after is nil (a light locked red)" do
      expect(refused_with(red_light.new(retry_after: nil, cool_off_time: 60)).retry_after).to eq(60)
      expect(refused_with(red_light.new(cool_off_time: 7.5)).retry_after).to eq(8)
    end

    it "uses cool_off_time from an error with no retry_after method" do
      cooling = Class.new(StandardError) { def cool_off_time = 20 }

      expect(refused_with(cooling.new).retry_after).to eq(20)
    end

    it "gives no retry_after for a non-positive cool_off_time" do
      expect(refused_with(red_light.new(cool_off_time: 0)).retry_after).to be_nil
    end

    it "gives no retry_after for an error that says nothing about waiting" do
      expect(refused_with(circuit_open.new("open")).retry_after).to be_nil
    end

    it "gives no retry_after, and still raises ProviderUnavailableError, when the accessor raises" do
      broken = Class.new(StandardError) { def retry_after = raise("boom") }

      error = refused_with(broken.new)

      expect(error).to be_a(StandardId::ProviderUnavailableError)
      expect(error.retry_after).to be_nil
    end

    it "is nil on a ProviderUnavailableError built without it" do
      expect(StandardId::ProviderUnavailableError.new(provider: :google).retry_after).to be_nil
    end
  end

  it "does not catch non-StandardError exceptions" do
    StandardId.config.network_wrapper = ->(&_block) { raise Interrupt }

    expect { described_class.run(provider: :google) { nil } }.to raise_error(Interrupt)
  end
end
