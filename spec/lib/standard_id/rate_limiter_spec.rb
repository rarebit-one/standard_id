require "rails_helper"

RSpec.describe StandardId::RateLimiter do
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(described_class::STORE).to receive(:increment) { |name, amount, **opts| memory_store.increment(name, amount, **opts) }
  end

  it "is the same store object the engine's controllers count on" do
    expect(StandardId::RateLimitHandling::RATE_LIMIT_STORE).to equal(described_class::STORE)
  end

  it "allows hits up to the limit and raises on the one past it" do
    3.times { expect { described_class.hit!("k", limit: 3, window: 1.minute) }.not_to raise_error }

    expect { described_class.hit!("k", limit: 3, window: 1.minute) }
      .to raise_error(StandardId::RateLimitExceededError, "Too many requests. Please try again later.") { |e|
        expect(e.retry_after).to eq(60)
      }
  end

  it "counts keys independently" do
    3.times { described_class.hit!("a", limit: 3, window: 1.minute) }

    expect { described_class.hit!("b", limit: 3, window: 1.minute) }.not_to raise_error
  end

  it "is off for a non-positive limit" do
    expect { 10.times { described_class.hit!("k", limit: 0, window: 1.minute) } }.not_to raise_error
    expect(memory_store.read("k")).to be_nil
  end

  it "is off when the store cannot count (NullStore answers nil)" do
    allow(described_class::STORE).to receive(:increment).and_return(nil)

    expect { 10.times { described_class.hit!("k", limit: 1, window: 1.minute) } }.not_to raise_error
  end

  it "renders through the OAuth error contract as 429 rate_limit_exceeded" do
    error = StandardId::RateLimitExceededError.new
    expect(error).to be_a(StandardId::InvalidRequestError)
    expect(error.http_status).to eq(:too_many_requests)
    expect(error.oauth_error_code).to eq(:rate_limit_exceeded)
  end
end
