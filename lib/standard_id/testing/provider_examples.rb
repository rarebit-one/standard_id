# RSpec support for host apps (and provider plugins) that want to pin down
# "this provider plugin is installed, registered, and its config fields are
# writable from config/initializers/standard_id.rb".
#
# Loaded automatically by `require "standard_id/testing"` when RSpec is
# present, or explicitly:
#
#   require "standard_id/testing/provider_examples"
#
# Shared example — the one-liner most apps want:
#
#   RSpec.describe "StandardId social providers" do
#     it_behaves_like "a registered StandardId provider", :google
#     it_behaves_like "a registered StandardId provider", :apple,
#                     config_fields: %i[apple_client_id apple_private_key apple_key_id apple_team_id]
#   end
#
# `config_fields:` defaults to every field in the provider's `config_schema`.
#
# Matcher — for ad-hoc assertions:
#
#   expect(:google).to be_a_registered_standard_id_provider
#   expect(:apple).to be_a_registered_standard_id_provider.with_config_fields(:apple_client_id, :apple_team_id)
#
require "standard_id"

module StandardId
  module Testing
    module ProviderExamples
      module_function

      # Problems preventing `name` from counting as a registered provider with
      # the given social config fields. Empty when all is well.
      #
      # @param name [Symbol, String]
      # @param fields [Array<Symbol>, nil] nil = the provider's config_schema keys
      # @return [Array<String>]
      def problems(name, fields = nil)
        return ["provider #{name.inspect} is not registered with StandardId::ProviderRegistry"] unless StandardId::ProviderRegistry.registered?(name)

        fields = config_fields_for(name) if fields.nil?
        fields.filter_map do |field|
          next "#{field} is not declared on the social config scope" unless StandardId::ConfigSchema.instance.field?(:social, field)

          begin
            StandardId.config.social.public_send(field)
            nil
          rescue StandardError => e
            "reading social.#{field} raised #{e.class}: #{e.message}"
          end
        end
      end

      def config_fields_for(name)
        StandardId::ProviderRegistry.get(name).config_schema.keys.map(&:to_sym)
      end

      # Write `value` through the same setter a host initializer uses, then
      # restore the field exactly — including "never assigned", so an ENV
      # fallback keeps working for later examples.
      def round_trip(field, value)
        social = StandardId.config.social
        assigned = social.assigned?(field)
        original = social.to_h[field.to_sym]
        social.public_send(:"#{field}=", value)
        social.public_send(field)
      ensure
        if assigned
          social[field.to_sym] = original
        else
          social.delete(field.to_sym)
        end
      end
    end
  end
end

if defined?(RSpec::Matchers) && RSpec::Matchers.respond_to?(:define)
  RSpec::Matchers.define :be_a_registered_standard_id_provider do
    chain(:with_config_fields) { |*fields| @fields = fields.flatten.map(&:to_sym) }

    match do |name|
      @problems = StandardId::Testing::ProviderExamples.problems(name, @fields)
      @problems.empty?
    end

    failure_message do |name|
      "expected #{name.inspect} to be a registered StandardId provider, but:\n  " + @problems.join("\n  ")
    end

    failure_message_when_negated do |name|
      "expected #{name.inspect} not to be a registered StandardId provider"
    end
  end
end

if defined?(RSpec) && RSpec.respond_to?(:shared_examples)
  RSpec.shared_examples "a registered StandardId provider" do |name, config_fields: nil|
    fields_for = -> { config_fields || StandardId::Testing::ProviderExamples.config_fields_for(name) }

    it "registers the #{name} provider" do
      expect(StandardId::ProviderRegistry.registered?(name)).to be(true),
        "#{name.inspect} is not registered — is its plugin gem in the Gemfile, and did the app boot its Railtie?"
    end

    it "declares the #{name} config fields on the social scope" do
      expect(name).to be_a_registered_standard_id_provider.with_config_fields(fields_for.call)
    end

    it "accepts writes to the #{name} config fields, as config/initializers/standard_id.rb does" do
      fields_for.call.each do |field|
        expect(StandardId::Testing::ProviderExamples.round_trip(field, "probe-value")).to eq("probe-value"),
          "writing social.#{field} did not round-trip"
      end
    end
  end
end
