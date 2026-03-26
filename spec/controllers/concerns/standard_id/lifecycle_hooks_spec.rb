require "rails_helper"

RSpec.describe StandardId::LifecycleHooks do
  let(:account) { Account.create!(name: "Test User", email: "scope-test@example.com") }

  # Build a minimal controller that includes the concern
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include StandardId::LifecycleHooks

      attr_accessor :mock_session_manager, :mock_request

      # Expose private methods for testing
      public :invoke_before_sign_in, :invoke_after_sign_in, :invoke_after_account_created, :current_scope_config

      def request
        mock_request || OpenStruct.new(path_parameters: {})
      end

      def session_manager
        mock_session_manager
      end
    end
  end

  let(:controller) { controller_class.new }

  let(:mock_request) do
    double("Request", path_parameters: {})
  end

  let(:mock_session_manager) do
    sm = double("SessionManager")
    allow(sm).to receive(:current_session).and_return(nil)
    sm
  end

  before do
    controller.mock_session_manager = mock_session_manager
    controller.mock_request = mock_request
    # Ensure no hooks are configured by default
    allow(StandardId.config).to receive(:before_sign_in).and_return(nil)
    allow(StandardId.config).to receive(:after_sign_in).and_return(nil)
    allow(StandardId.config).to receive(:after_account_created).and_return(nil)
  end

  # ─────────────────────────────────────────────────────────────────────────
  # current_scope_config
  # ─────────────────────────────────────────────────────────────────────────
  describe "#current_scope_config" do
    it "returns nil when no scope is in path_parameters" do
      allow(mock_request).to receive(:path_parameters).and_return({})
      expect(controller.current_scope_config).to be_nil
    end

    it "returns nil when scope is in path_parameters but not configured" do
      allow(mock_request).to receive(:path_parameters).and_return({ scope: :unknown })
      allow(StandardId).to receive(:scope_for).with(:unknown).and_return(nil)
      expect(controller.current_scope_config).to be_nil
    end

    it "returns the ScopeConfig when scope is configured" do
      scope_config = StandardId::ScopeConfig.new(:borrower, { profile_type: "BorrowerProfile" })
      allow(mock_request).to receive(:path_parameters).and_return({ scope: :borrower })
      allow(StandardId).to receive(:scope_for).with(:borrower).and_return(scope_config)

      result = controller.current_scope_config
      expect(result).to be_a(StandardId::ScopeConfig)
      expect(result.name).to eq(:borrower)
    end

    it "ignores scope passed as a query param (not in path_parameters)" do
      allow(mock_request).to receive(:path_parameters).and_return({})
      # Even if scope appears in regular params, it should be ignored
      expect(controller.current_scope_config).to be_nil
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Backward compatibility — no scope
  # ─────────────────────────────────────────────────────────────────────────
  describe "backward compatibility (no scope)" do
    before { allow(mock_request).to receive(:path_parameters).and_return({}) }

    it "invoke_before_sign_in works without scope" do
      expect { controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil }) }.not_to raise_error
    end

    it "invoke_after_sign_in returns nil without scope or hook" do
      result = controller.invoke_after_sign_in(account, { mechanism: "password", provider: nil })
      expect(result).to be_nil
    end

    it "invoke_after_account_created works without scope" do
      expect { controller.invoke_after_account_created(account, { mechanism: "signup", provider: nil }) }.not_to raise_error
    end

    it "invoke_before_sign_in calls hook without scope fields" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

      expect(received_context).to include(mechanism: "password", provider: nil)
      expect(received_context).not_to have_key(:scope)
      expect(received_context).not_to have_key(:profile_type)
      expect(received_context).not_to have_key(:after_sign_in_path)
    end

    it "invoke_after_sign_in calls hook without scope fields" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      controller.invoke_after_sign_in(account, { mechanism: "password", provider: nil })

      expect(received_context).not_to have_key(:scope)
      expect(received_context).not_to have_key(:profile_type)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # RAR-95: Scope context in hooks
  # ─────────────────────────────────────────────────────────────────────────
  describe "scope context in hooks" do
    let(:scope_config) do
      StandardId::ScopeConfig.new(:borrower, {
        profile_type: "BorrowerProfile",
        after_sign_in_path: "/borrower/dashboard",
        no_profile_message: "No access."
      })
    end

    before do
      allow(mock_request).to receive(:path_parameters).and_return({ scope: :borrower })
      allow(StandardId).to receive(:scope_for).with(:borrower).and_return(scope_config)
      # Disable profile check for scope context tests (no profile_type requirement)
      allow(StandardId.config).to receive(:profile_resolver).and_return(->(account, profile_type) { true })
    end

    it "merges scope info into before_sign_in context" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

      expect(received_context[:scope]).to eq(:borrower)
      expect(received_context[:profile_type]).to eq("BorrowerProfile")
      expect(received_context[:after_sign_in_path]).to eq("/borrower/dashboard")
    end

    it "merges scope info into after_sign_in context" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      controller.invoke_after_sign_in(account, { mechanism: "password", provider: nil })

      expect(received_context[:scope]).to eq(:borrower)
      expect(received_context[:profile_type]).to eq("BorrowerProfile")
      expect(received_context[:after_sign_in_path]).to eq("/borrower/dashboard")
    end

    it "merges scope info into after_account_created context" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
      }
      allow(StandardId.config).to receive(:after_account_created).and_return(hook)

      controller.invoke_after_account_created(account, { mechanism: "signup", provider: nil })

      expect(received_context[:scope]).to eq(:borrower)
      expect(received_context[:profile_type]).to eq("BorrowerProfile")
      expect(received_context[:after_sign_in_path]).to eq("/borrower/dashboard")
    end

    it "uses scope after_sign_in_path as default redirect when hook returns nil" do
      hook = ->(_account, _request, _context) { nil }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      result = controller.invoke_after_sign_in(account, { mechanism: "password", provider: nil })

      expect(result).to eq("/borrower/dashboard")
    end

    it "uses scope after_sign_in_path when no hook is configured" do
      result = controller.invoke_after_sign_in(account, { mechanism: "password", provider: nil })

      expect(result).to eq("/borrower/dashboard")
    end

    it "uses hook redirect override instead of scope path when hook returns a path" do
      hook = ->(_account, _request, _context) { "/custom-onboarding" }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      result = controller.invoke_after_sign_in(account, { mechanism: "password", provider: nil })

      expect(result).to eq("/custom-onboarding")
    end

    it "preserves original context fields alongside scope fields" do
      received_context = nil
      hook = lambda { |_account, _request, context|
        received_context = context
        nil
      }
      allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

      controller.invoke_before_sign_in(account, { mechanism: "social", provider: "google" })

      expect(received_context[:mechanism]).to eq("social")
      expect(received_context[:provider]).to eq("google")
      expect(received_context[:scope]).to eq(:borrower)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # RAR-96: Built-in profile validation
  # ─────────────────────────────────────────────────────────────────────────
  describe "built-in profile validation" do
    let(:scope_config) do
      StandardId::ScopeConfig.new(:borrower, {
        profile_type: "BorrowerProfile",
        after_sign_in_path: "/borrower/dashboard",
        no_profile_message: "No access."
      })
    end

    before do
      allow(mock_request).to receive(:path_parameters).and_return({ scope: :borrower })
      allow(StandardId).to receive(:scope_for).with(:borrower).and_return(scope_config)
    end

    context "when profile resolver returns false" do
      before do
        allow(StandardId.config).to receive(:profile_resolver).and_return(
          ->(_account, _profile_type) { false }
        )
      end

      it "raises AuthenticationDenied with the scope's no_profile_message" do
        expect {
          controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
        }.to raise_error(StandardId::AuthenticationDenied, "No access.")
      end

      it "does not call the app's custom before_sign_in hook" do
        hook = instance_double(Proc)
        allow(hook).to receive(:respond_to?).with(:call).and_return(true)
        allow(hook).to receive(:call)
        allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

        expect {
          controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
        }.to raise_error(StandardId::AuthenticationDenied)

        expect(hook).not_to have_received(:call)
      end
    end

    context "when profile resolver returns true" do
      before do
        allow(StandardId.config).to receive(:profile_resolver).and_return(
          ->(_account, _profile_type) { true }
        )
      end

      it "does not raise and proceeds normally" do
        expect {
          controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
        }.not_to raise_error
      end

      it "calls the app's custom before_sign_in hook after profile check passes" do
        hook_called = false
        hook = lambda { |_account, _request, _context|
          hook_called = true
          nil
        }
        allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

        expect(hook_called).to be true
      end
    end

    context "when scope does not require a profile (no profile_type)" do
      let(:scope_config) do
        StandardId::ScopeConfig.new(:public, {
          after_sign_in_path: "/public/home"
        })
      end

      before do
        allow(StandardId).to receive(:scope_for).with(:borrower).and_return(scope_config)
      end

      it "does not call the profile resolver" do
        resolver = instance_double(Proc)
        allow(resolver).to receive(:call)
        allow(StandardId.config).to receive(:profile_resolver).and_return(resolver)

        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

        expect(resolver).not_to have_received(:call)
      end

      it "proceeds normally without raising" do
        expect {
          controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
        }.not_to raise_error
      end
    end

    context "when profile check passes but custom hook rejects" do
      before do
        allow(StandardId.config).to receive(:profile_resolver).and_return(
          ->(_account, _profile_type) { true }
        )
      end

      it "raises AuthenticationDenied from the custom hook" do
        hook = ->(_account, _request, _context) { { error: "Account suspended" } }
        allow(StandardId.config).to receive(:before_sign_in).and_return(hook)

        expect {
          controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
        }.to raise_error(StandardId::AuthenticationDenied, "Account suspended")
      end
    end

    it "passes the correct profile_type to the resolver" do
      received_profile_type = nil
      resolver = lambda { |_account, profile_type|
        received_profile_type = profile_type
        true
      }
      allow(StandardId.config).to receive(:profile_resolver).and_return(resolver)

      controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

      expect(received_profile_type).to eq("BorrowerProfile")
    end

    it "passes the account to the resolver" do
      received_account = nil
      resolver = lambda { |acct, _profile_type|
        received_account = acct
        true
      }
      allow(StandardId.config).to receive(:profile_resolver).and_return(resolver)

      controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

      expect(received_account).to eq(account)
    end

    context "when profile_resolver is nil (default fallback)" do
      let(:profiles_relation) { double("profiles") }
      let(:sessions_relation) { double("sessions", where: double(active: double(count: 0))) }
      let(:account_with_profiles) { double("Account", profiles: profiles_relation, sessions: sessions_relation) }

      before do
        allow(StandardId.config).to receive(:profile_resolver).and_return(nil)
      end

      it "uses the built-in default resolver and denies when no matching profile exists" do
        allow(profiles_relation).to receive(:exists?).and_return(false)

        expect {
          controller.invoke_before_sign_in(account_with_profiles, { mechanism: "password", provider: nil })
        }.to raise_error(StandardId::AuthenticationDenied, "No access.")

        expect(profiles_relation).to have_received(:exists?).with(profileable_type: "BorrowerProfile")
      end

      it "uses the built-in default resolver and allows when matching profile exists" do
        allow(profiles_relation).to receive(:exists?).and_return(true)

        expect {
          controller.invoke_before_sign_in(account_with_profiles, { mechanism: "password", provider: nil })
        }.not_to raise_error
      end
    end

    it "uses default no_profile_message when none is configured" do
      scope_config = StandardId::ScopeConfig.new(:lender, { profile_type: "LenderProfile" })
      allow(StandardId).to receive(:scope_for).with(:borrower).and_return(scope_config)
      allow(StandardId.config).to receive(:profile_resolver).and_return(
        ->(_account, _profile_type) { false }
      )

      expect {
        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
      }.to raise_error(StandardId::AuthenticationDenied, "Access denied. No matching profile found.")
    end
  end
end
