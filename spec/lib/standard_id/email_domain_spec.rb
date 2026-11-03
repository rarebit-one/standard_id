require "rails_helper"

RSpec.describe StandardId::EmailDomain do
  describe ".registered_tld?" do
    # Offline: judged against the bundled Public Suffix List, never DNS.
    %w[
      jaryl@rarebit.ome
      user@example.con
      user@example.invalidtld
      user@example.test
      user@localhost
      user@com
      rarebit.ome
    ].each do |input|
      it "rejects #{input.inspect}" do
        expect(described_class.registered_tld?(input)).to be(false)
      end
    end

    %w[
      jaryl@rarebit.one
      user@example.com
      user@example.sg
      user@example.co.uk
      user@example.app
      user@example.xn--p1ai
      user@пример.рф
      user@mail.example.com
      user@foo.blogspot.com
      example.co.uk
    ].each do |input|
      it "accepts #{input.inspect}" do
        expect(described_class.registered_tld?(input)).to be(true)
      end
    end

    it "ignores case" do
      expect(described_class.registered_tld?("User@Example.COM")).to be(true)
      expect(described_class.registered_tld?("USER@EXAMPLE.XN--P1AI")).to be(true)
      expect(described_class.registered_tld?("User@Rarebit.OME")).to be(false)
    end

    it "ignores surrounding whitespace" do
      expect(described_class.registered_tld?("  user@example.com \n")).to be(true)
      expect(described_class.registered_tld?(" user@rarebit.ome ")).to be(false)
    end

    it "accepts a fully-qualified domain with a trailing root dot" do
      expect(described_class.registered_tld?("user@example.com.")).to be(true)
    end

    it "is false for blank or nil input" do
      expect(described_class.registered_tld?(nil)).to be(false)
      expect(described_class.registered_tld?("")).to be(false)
      expect(described_class.registered_tld?("user@")).to be(false)
    end

    it "rejects an over-long label or domain without decoding it" do
      expect(StandardId::EmailDomain::Punycode).not_to receive(:decode)

      expect(described_class.registered_tld?("a@xn--#{"9" * 100_000}.com")).to be(false)
      expect(described_class.registered_tld?("a@#{"a" * 64}.com")).to be(false)
      expect(described_class.registered_tld?("a@#{(["a" * 60] * 5).join(".")}.com")).to be(false)
    end

    it "accepts a label of exactly 63 characters" do
      expect(described_class.registered_tld?("a@#{"a" * 63}.com")).to be(true)
    end

    it "is false for a malformed punycode label rather than raising" do
      expect(described_class.registered_tld?("user@example.xn--!!")).to be(false)
      expect(described_class.registered_tld?("user@example.xn--zzzzzzzzzz")).to be(false)
    end
  end

  describe ".allowed?" do
    it "accepts a registered TLD" do
      expect(described_class.allowed?("jaryl@rarebit.one")).to be(true)
    end

    it "rejects a TLD that is neither registered nor special-use" do
      expect(described_class.allowed?("jaryl@rarebit.ome")).to be(false)
      expect(described_class.allowed?("user@example.invalidtld")).to be(false)
      expect(described_class.allowed?("user@printer.lan")).to be(false)
    end

    %w[user@example.test bot@agents.app.invalid user@mail.example user@localhost e2e@test.local User@Demo.INVALID].each do |input|
      it "accepts the special-use TLD in #{input.inspect} by default" do
        expect(described_class.allowed?(input)).to be(true)
      end
    end

    it "follows email.allowed_special_use_tlds" do
      allow(StandardId.config.email).to receive(:allowed_special_use_tlds).and_return([".Internal"])

      expect(described_class.allowed?("user@host.internal")).to be(true)
      expect(described_class.allowed?("user@example.test")).to be(false)
    end

    it "accepts registered TLDs only when the list is empty" do
      allow(StandardId.config.email).to receive(:allowed_special_use_tlds).and_return([])

      expect(described_class.allowed?("bot@agents.app.invalid")).to be(false)
      expect(described_class.allowed?("user@example.com")).to be(true)
    end
  end

  describe ".validation_error" do
    it "names the domain when the TLD is not registered" do
      expect(described_class.validation_error(" Jaryl@Rarebit.OME "))
        .to eq("rarebit.ome isn't a valid e-mail domain. Check the address.")
    end

    it "is nil for a registered TLD" do
      expect(described_class.validation_error("jaryl@rarebit.one")).to be_nil
    end

    it "is nil for a default special-use TLD" do
      expect(described_class.validation_error("bot@agents.app.invalid")).to be_nil
    end

    it "is nil when email.require_registered_tld is off" do
      allow(StandardId.config.email).to receive(:require_registered_tld).and_return(false)

      expect(described_class.validation_error("jaryl@rarebit.ome")).to be_nil
    end
  end

  describe StandardId::EmailDomain::Punycode do
    it "refuses input longer than a DNS label" do
      expect { described_class.decode("9" * 64) }.to raise_error(ArgumentError, /too long/)
    end

    # RFC 3492 section 7.1 and well-known IDN TLDs.
    {
      "p1ai" => "рф",
      "e1afmkfd" => "пример",
      "mgbaam7a8h" => "امارات",
      "fiqs8s" => "中国",
      "bcher-kva" => "bücher",
      "egbpdaj6bu4bxfgehfvwxn" => "ليهمابتكلموشعربي؟"
    }.each do |ascii, unicode|
      it "decodes #{ascii} to #{unicode}" do
        expect(described_class.decode(ascii)).to eq(unicode)
      end
    end
  end
end
