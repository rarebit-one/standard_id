require "rails_helper"

RSpec.describe StandardId::Config::CallableValidator do
  # Defined as `let` rather than a constant inside `describe` — Ruby hoists
  # constants inside `RSpec.describe` to the top level, which collides with
  # any other spec defining the same name.
  let(:fields_to_snapshot) do
    %w[
      profile_resolver
      sentry_context
      after_account_created
      before_sign_in
      after_sign_in
      passwordless.username_validator
      passwordless.account_factory
      oauth.custom_claims
      oauth.claim_resolvers
    ].freeze
  end

  # Snapshot each configured field and restore it afterwards so mutations
  # inside one example do not leak into the next.
  around do |example|
    snapshot = fields_to_snapshot.to_h { |path| [path, read_field(path)] }
    example.run
  ensure
    snapshot.each { |path, value| write_field(path, value) }
  end

  def read_field(path)
    path.split(".").inject(StandardId.config) { |receiver, seg| receiver.public_send(seg) }
  end

  def write_field(path, value)
    segments = path.split(".")
    target = segments[0..-2].inject(StandardId.config) { |receiver, seg| receiver.public_send(seg) }
    target.public_send("#{segments.last}=", value)
  end

  describe ".validate!" do
    context "when no callables are configured" do
      it "passes silently" do
        expect { described_class.validate! }.not_to raise_error
      end
    end

    context "positional callables" do
      it "accepts a lambda with the exact expected arity" do
        StandardId.config.before_sign_in = ->(_account, _request, _context) { nil }
        expect { described_class.validate! }.not_to raise_error
      end

      it "accepts a lambda with a splat (arity < 0)" do
        StandardId.config.after_sign_in = ->(*_args) { nil }
        expect { described_class.validate! }.not_to raise_error
      end

      it "accepts a lambda with optional params that can still absorb the expected call" do
        StandardId.config.after_sign_in = ->(_account, _request, _context = nil) { nil }
        expect { described_class.validate! }.not_to raise_error
      end

      it "rejects a lambda whose optional params cannot absorb the expected arity" do
        StandardId.config.after_sign_in = ->(_account, _request = nil) { nil }
        expect { described_class.validate! }.to raise_error(
          StandardId::ConfigurationError,
          /`after_sign_in` expects signature \(account, request, context\) \(arity 3\)/
        )
      end

      it "raises when a lambda has the wrong positional arity" do
        StandardId.config.after_sign_in = ->(_account) { nil }
        expect { described_class.validate! }.to raise_error(
          StandardId::ConfigurationError,
          /`after_sign_in` expects signature \(account, request, context\) \(arity 3\), got arity 1/
        )
      end

      it "raises for profile_resolver arity mismatch with a clear message" do
        StandardId.config.profile_resolver = ->(_account) { true }
        expect { described_class.validate! }.to raise_error(
          StandardId::ConfigurationError,
          /`profile_resolver`.*arity 2.*got arity 1/
        )
      end

      it "accepts method references with matching arity" do
        klass = Class.new do
          def self.call(_a, _b) = true
        end
        StandardId.config.profile_resolver = klass.method(:call)
        expect { described_class.validate! }.not_to raise_error
      end

      it "rejects method references with the wrong arity" do
        klass = Class.new do
          def self.call(_a) = true
        end
        StandardId.config.profile_resolver = klass.method(:call)
        expect { described_class.validate! }.to raise_error(StandardId::ConfigurationError)
      end

      it "ignores non-callable values" do
        StandardId.config.before_sign_in = "not a callable"
        expect { described_class.validate! }.not_to raise_error
      end
    end

    context "keyword callables" do
      it "accepts a lambda with only allowed keywords" do
        StandardId.config.oauth.custom_claims = ->(account:, client:, **) { { id: account&.id } }
        expect { described_class.validate! }.not_to raise_error
      end

      it "accepts a lambda with a double-splat catch-all" do
        StandardId.config.oauth.custom_claims = ->(**_kw) { {} }
        expect { described_class.validate! }.not_to raise_error
      end

      it "raises when custom_claims declares an unknown keyword" do
        StandardId.config.oauth.custom_claims = ->(account:, session:) { {} }
        expect { described_class.validate! }.to raise_error(
          StandardId::ConfigurationError,
          /`oauth.custom_claims`.*unknown keyword argument\(s\) \[:session\]/
        )
      end

      it "validates account_factory keywords" do
        StandardId.config.passwordless.account_factory = ->(identifier:, params:, request:) { nil }
        expect { described_class.validate! }.not_to raise_error
      end

      it "raises when account_factory uses unexpected keywords" do
        StandardId.config.passwordless.account_factory = ->(identifier:, params:, account:) { nil }
        expect { described_class.validate! }.to raise_error(
          StandardId::ConfigurationError,
          /`passwordless.account_factory`.*\[:account\]/
        )
      end
    end

    context "claim_resolvers" do
      it "accepts resolvers that only use allowed keywords" do
        StandardId.config.oauth.claim_resolvers = {
          "role" => ->(account:, **) { account&.role }
        }
        expect { described_class.validate! }.not_to raise_error
      end

      it "raises when a resolver uses an unknown keyword" do
        StandardId.config.oauth.claim_resolvers = {
          "role" => ->(account:, tenant:) { nil }
        }
        expect { described_class.validate! }.to raise_error(
          StandardId::ConfigurationError,
          /oauth.claim_resolvers\["role"\].*\[:tenant\]/
        )
      end

      it "ignores non-callable entries" do
        StandardId.config.oauth.claim_resolvers = { "role" => "not callable" }
        expect { described_class.validate! }.not_to raise_error
      end
    end
  end
end
