require "rails_helper"

RSpec.describe StandardId::Utils::IpNormalizer do
  describe ".normalize" do
    it "converts IPv6 localhost to IPv4 localhost" do
      expect(described_class.normalize("::1")).to eq("127.0.0.1")
    end

    it "returns IPv4 localhost unchanged" do
      expect(described_class.normalize("127.0.0.1")).to eq("127.0.0.1")
    end

    it "returns regular IPv4 addresses unchanged" do
      expect(described_class.normalize("192.168.1.1")).to eq("192.168.1.1")
    end

    it "returns regular IPv6 addresses unchanged" do
      expect(described_class.normalize("2001:0db8:85a3::8a2e:0370:7334")).to eq("2001:0db8:85a3::8a2e:0370:7334")
    end

    it "returns nil unchanged" do
      expect(described_class.normalize(nil)).to be_nil
    end
  end
end
