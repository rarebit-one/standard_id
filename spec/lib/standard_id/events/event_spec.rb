require "rails_helper"

RSpec.describe StandardId::Events::Event do
  let(:payload) do
    {
      event_type: "test.event",
      event_id: "abc-123",
      timestamp: "2025-11-29T10:00:00Z",
      account: double("Account", id: 1),
      ip_address: "127.0.0.1"
    }
  end

  let(:started_at) { Time.current - 0.1 }
  let(:finished_at) { Time.current }

  subject(:event) do
    described_class.new(
      name: "standard_id.test.event",
      payload: payload,
      started_at: started_at,
      finished_at: finished_at,
      transaction_id: "tx-123"
    )
  end

  describe "#short_name" do
    it "removes the namespace prefix" do
      expect(event.short_name).to eq("test.event")
    end

    context "when name has no namespace" do
      subject(:event) do
        described_class.new(name: "plain.event", payload: {})
      end

      it "returns the full name" do
        expect(event.short_name).to eq("plain.event")
      end
    end
  end

  describe "#event_type" do
    it "returns the event_type from payload" do
      expect(event.event_type).to eq("test.event")
    end
  end

  describe "#event_id" do
    it "returns the event_id from payload" do
      expect(event.event_id).to eq("abc-123")
    end
  end

  describe "#timestamp" do
    it "returns the timestamp from payload" do
      expect(event.timestamp).to eq("2025-11-29T10:00:00Z")
    end
  end

  describe "#duration_ms" do
    it "calculates duration in milliseconds" do
      expect(event.duration_ms).to be_within(10).of(100)
    end

    context "when timing is not available" do
      subject(:event) do
        described_class.new(name: "test", payload: {})
      end

      it "returns nil" do
        expect(event.duration_ms).to be_nil
      end
    end
  end

  describe "#[]" do
    it "accesses payload values by symbol key" do
      expect(event[:ip_address]).to eq("127.0.0.1")
    end

    it "accesses payload values by string key" do
      expect(event["ip_address"]).to eq("127.0.0.1")
    end

    it "returns nil for missing keys" do
      expect(event[:nonexistent]).to be_nil
    end
  end

  describe "#key?" do
    it "returns true for existing keys" do
      expect(event.key?(:ip_address)).to be true
    end

    it "returns false for missing keys" do
      expect(event.key?(:nonexistent)).to be false
    end
  end

  describe "#to_h" do
    it "returns a hash representation" do
      result = event.to_h

      expect(result[:name]).to eq("standard_id.test.event")
      expect(result[:short_name]).to eq("test.event")
      expect(result[:transaction_id]).to eq("tx-123")
      expect(result[:duration_ms]).to be_within(10).of(100)
      expect(result[:payload]["ip_address"]).to eq("127.0.0.1")
    end
  end

  describe "#to_json" do
    it "returns a JSON string" do
      json = event.to_json
      parsed = JSON.parse(json)

      expect(parsed["name"]).to eq("standard_id.test.event")
      expect(parsed["short_name"]).to eq("test.event")
    end
  end

  describe "#inspect" do
    it "returns a readable string representation" do
      result = event.inspect

      expect(result).to include("StandardId::Events::Event")
      expect(result).to include("standard_id.test.event")
      expect(result).to include("abc-123")
    end
  end

  describe "payload access with indifferent access" do
    it "allows accessing payload with both string and symbol keys" do
      expect(event.payload[:ip_address]).to eq("127.0.0.1")
      expect(event.payload["ip_address"]).to eq("127.0.0.1")
    end
  end
end
