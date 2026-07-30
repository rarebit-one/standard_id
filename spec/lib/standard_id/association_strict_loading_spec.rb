require "rails_helper"

RSpec.describe StandardId::AssociationStrictLoading do
  # An Account-shaped class that includes the concern on demand, so the
  # `included do` block runs with whatever config the example has set. This is
  # the only way to exercise declaration-time behaviour: the real Account's
  # class body ran once, at boot.
  def account_like_class
    Class.new(ApplicationRecord) do
      self.table_name = "accounts"
      def self.name = "AnonymousAccount"
      include StandardId::AccountAssociations
    end
  end

  describe ".option" do
    it "returns an EMPTY HASH when unconfigured, so no option is declared" do
      StandardId.config.association_strict_loading = nil

      expect(described_class.option).to eq({})
    end

    it "returns the option when configured false" do
      StandardId.config.association_strict_loading = false

      expect(described_class.option).to eq({ strict_loading: false })
    end

    it "returns the option when configured true" do
      StandardId.config.association_strict_loading = true

      expect(described_class.option).to eq({ strict_loading: true })
    end
  end

  # This is the backward-compatibility guarantee, and it is not cosmetic.
  # Rails checks `reflection.options.key?(:strict_loading)` BEFORE consulting the
  # owner (Association#violates_strict_loading?), so declaring
  # `strict_loading: nil` would put the key in the hash, make
  # `reflection.strict_loading?` return false, and silently disable strict
  # loading on every gem association in every app that never asked for it.
  describe "declaration-time behaviour" do
    context "when unconfigured (the default)" do
      it "omits the :strict_loading key entirely from every association" do
        StandardId.config.association_strict_loading = nil
        klass = account_like_class

        described_class::ACCOUNT_ASSOCIATIONS.each do |name|
          options = klass.reflect_on_association(name).options
          expect(options).not_to have_key(:strict_loading), "expected #{name} to omit :strict_loading"
        end
      end

      it "leaves the owner's strict_loading_by_default governing" do
        StandardId.config.association_strict_loading = nil
        klass = account_like_class
        reflection = klass.reflect_on_association(:sessions)

        expect(reflection.options.key?(:strict_loading)).to be false
      end
    end

    context "when configured false" do
      it "declares strict_loading: false on every association, including the :through" do
        StandardId.config.association_strict_loading = false
        klass = account_like_class

        described_class::ACCOUNT_ASSOCIATIONS.each do |name|
          reflection = klass.reflect_on_association(name)
          expect(reflection.options[:strict_loading]).to be(false), "expected #{name} to be opted out"
        end

        expect(klass.reflect_on_association(:credentials).through_reflection).to be_present
      end
    end

    context "when configured true" do
      it "declares strict_loading: true on every association" do
        StandardId.config.association_strict_loading = true
        klass = account_like_class

        described_class::ACCOUNT_ASSOCIATIONS.each do |name|
          expect(klass.reflect_on_association(name).options[:strict_loading]).to be(true)
        end
      end
    end
  end

  describe "the real boot-time declarations" do
    it "left Account's associations untouched, since the default is nil" do
      described_class::ACCOUNT_ASSOCIATIONS.each do |name|
        expect(Account.reflect_on_association(name).options).not_to have_key(:strict_loading)
      end
    end

    it "covers Session#refresh_tokens and Identifier#credentials too" do
      expect(StandardId::Session.reflect_on_association(:refresh_tokens)).to be_present
      expect(StandardId::Identifier.reflect_on_association(:credentials)).to be_present
    end
  end

  describe ".verify_consistency!" do
    it "does nothing when unconfigured" do
      StandardId.config.association_strict_loading = nil

      expect { described_class.verify_consistency! }.not_to raise_error
    end

    # The failure mode this exists for: the `included do` block reads the config
    # when the HOST's Account class body runs, which can be before an
    # initializer sets it. Nothing raises at that point; the app just behaves as
    # though the setting were never made.
    it "raises a ConfigurationError naming the ordering problem when a declaration disagrees" do
      StandardId.config.association_strict_loading = false

      expect { described_class.verify_consistency! }.to raise_error(
        StandardId::ConfigurationError, /class body ran BEFORE the config was set/
      )
    end

    it "names the offending associations" do
      StandardId.config.association_strict_loading = false

      expect { described_class.verify_consistency! }.to raise_error(/Account#sessions/)
    end

    it "passes when the declarations agree with the config" do
      StandardId.config.association_strict_loading = false
      klass = account_like_class
      allow(described_class).to receive(:mismatched_associations).and_return([])

      expect(klass.reflect_on_association(:sessions).options[:strict_loading]).to be false
      expect { described_class.verify_consistency! }.not_to raise_error
    end
  end

  describe ".mismatched_associations" do
    it "reports nothing when the account class cannot be resolved" do
      StandardId.config.account_class_name = "NoSuchAccountClass"

      expect(described_class.mismatched_associations(nil)).to eq([])
    end
  end
end
