require "rails_helper"

RSpec.describe StandardId::LifecycleHooks do
  let(:account) { Account.create!(name: "Test User", email: "scope-test@example.com") }

  # Build a minimal controller that includes the concern
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include StandardId::LifecycleHooks

      attr_accessor :mock_session_manager, :mock_request, :redirected_to, :redirect_options

      # Expose private methods for testing
      public :invoke_before_sign_in, :invoke_after_sign_in, :invoke_after_account_created,
             :current_scope_config, :current_scope_name, :resolve_profile_for_authorizer,
             :handle_authentication_denied

      def request
        mock_request || OpenStruct.new(path_parameters: {})
      end

      def session_manager
        mock_session_manager
      end

      # Stub redirect_to so we can invoke handle_authentication_denied without
      # a full controller lifecycle.
      def redirect_to(target, options = {})
        @redirected_to = target
        @redirect_options = options
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
      scope_config = StandardId::ScopeConfig::DEPRECATOR.silence do
        StandardId::ScopeConfig.new(:borrower, { profile_type: "BorrowerProfile" })
      end
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

    it "skips scope after_sign_in_path when caller supplied a redirect_uri and hook returned nil (defer signal)" do
      hook = ->(_account, _request, _context) { nil }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      result = controller.invoke_after_sign_in(
        account,
        { mechanism: "password", provider: nil, redirect_uri: "/oauth/authorize?client_id=harness" }
      )

      expect(result).to be_nil
    end

    it "still uses scope after_sign_in_path when context has no redirect_uri (defer signal absent)" do
      hook = ->(_account, _request, _context) { nil }
      allow(StandardId.config).to receive(:after_sign_in).and_return(hook)

      result = controller.invoke_after_sign_in(
        account,
        { mechanism: "password", provider: nil, redirect_uri: nil }
      )

      expect(result).to eq("/borrower/dashboard")
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
      let(:sessions_relation) { double("sessions", where: double(active: double(exists?: false))) }
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
      scope_config = StandardId::ScopeConfig.new(:lender, { profile_types: ["LenderProfile"] })
      allow(StandardId).to receive(:scope_for).with(:borrower).and_return(scope_config)
      allow(StandardId.config).to receive(:profile_resolver).and_return(
        ->(_account, _profile_type) { false }
      )

      expect {
        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
      }.to raise_error(StandardId::AuthenticationDenied, "Access denied. No matching profile found.")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # scope_resolver callback — decouples scope lookup from URL conventions
  # ─────────────────────────────────────────────────────────────────────────
  describe "scope_resolver callback" do
    let(:scope_config) do
      StandardId::ScopeConfig.new(:admin, {
        profile_types: ["AdminProfile"],
        after_sign_in_path: "/admin"
      })
    end

    before do
      allow(StandardId).to receive(:scope_for).and_call_original
      allow(StandardId).to receive(:scope_for).with(:admin).and_return(scope_config)
    end

    it "uses the default resolver (reads request.path_parameters[:scope]) when config.scope_resolver is nil" do
      allow(StandardId.config).to receive(:scope_resolver).and_return(nil)
      allow(mock_request).to receive(:path_parameters).and_return({ scope: :admin })

      expect(controller.current_scope_name).to eq(:admin)
      expect(controller.current_scope_config).to eq(scope_config)
    end

    it "resolves the scope from a custom path parameter (e.g. :control_plane)" do
      custom_resolver = ->(request:, session:) {
        cp = request.path_parameters[:control_plane]
        { "admin-portal" => :admin }[cp]
      }
      allow(StandardId.config).to receive(:scope_resolver).and_return(custom_resolver)
      allow(mock_request).to receive(:path_parameters).and_return({ control_plane: "admin-portal" })

      expect(controller.current_scope_name).to eq(:admin)
      expect(controller.current_scope_config).to eq(scope_config)
    end

    it "resolves the scope from the request subdomain" do
      subdomain_resolver = ->(request:, session:) { request.subdomain.to_sym if request.subdomain.present? }
      allow(StandardId.config).to receive(:scope_resolver).and_return(subdomain_resolver)
      allow(mock_request).to receive(:path_parameters).and_return({})
      allow(mock_request).to receive(:subdomain).and_return("admin")

      expect(controller.current_scope_name).to eq(:admin)
      expect(controller.current_scope_config).to eq(scope_config)
    end

    it "receives the current session object for session-based resolution" do
      captured_session = nil
      session_resolver = ->(request:, session:) {
        captured_session = session
        :admin
      }
      fake_session = double("Session")
      allow(mock_session_manager).to receive(:current_session).and_return(fake_session)
      allow(StandardId.config).to receive(:scope_resolver).and_return(session_resolver)
      allow(mock_request).to receive(:path_parameters).and_return({})

      expect(controller.current_scope_name).to eq(:admin)
      expect(captured_session).to eq(fake_session)
    end

    it "returns nil when the custom resolver returns nil" do
      allow(StandardId.config).to receive(:scope_resolver).and_return(
        ->(request:, session:) { nil }
      )

      expect(controller.current_scope_name).to be_nil
      expect(controller.current_scope_config).to be_nil
    end

    it "falls back to the default resolver when config.scope_resolver is set to a non-callable" do
      allow(StandardId.config).to receive(:scope_resolver).and_return(:not_callable)
      allow(mock_request).to receive(:path_parameters).and_return({ scope: :admin })

      expect { controller.current_scope_name }.not_to raise_error
      expect(controller.current_scope_name).to eq(:admin)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # profile_types (plural) — multi-profile-type scopes
  # ─────────────────────────────────────────────────────────────────────────
  describe "multi profile_types scope" do
    let(:scope_config) do
      StandardId::ScopeConfig.new(:lender, {
        profile_types: ["OrganisationProfile", "BorrowerProfile"],
        after_sign_in_path: "/lender",
        no_profile_message: "Not a lender."
      })
    end

    before do
      allow(mock_request).to receive(:path_parameters).and_return({ scope: :lender })
      allow(StandardId).to receive(:scope_for).with(:lender).and_return(scope_config)
    end

    it "allows an account with a matching OrganisationProfile" do
      resolver = ->(_account, type) { type == "OrganisationProfile" }
      allow(StandardId.config).to receive(:profile_resolver).and_return(resolver)

      expect {
        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
      }.not_to raise_error
    end

    it "allows an account with a matching BorrowerProfile (second type tried)" do
      resolver = ->(_account, type) { type == "BorrowerProfile" }
      allow(StandardId.config).to receive(:profile_resolver).and_return(resolver)

      expect {
        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
      }.not_to raise_error
    end

    it "denies an account with neither profile type" do
      allow(StandardId.config).to receive(:profile_resolver).and_return(
        ->(_account, _type) { false }
      )

      expect {
        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
      }.to raise_error(StandardId::AuthenticationDenied, "Not a lender.")
    end

    it "merges :profile_types and (first) :profile_type into the hook context" do
      received_context = nil
      allow(StandardId.config).to receive(:profile_resolver).and_return(->(_a, _t) { true })
      allow(StandardId.config).to receive(:before_sign_in).and_return(
        ->(_account, _request, context) { received_context = context; nil }
      )

      controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

      expect(received_context[:profile_types]).to eq(["OrganisationProfile", "BorrowerProfile"])
      expect(received_context[:profile_type]).to eq("OrganisationProfile")
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Per-scope :authorizer callable
  # ─────────────────────────────────────────────────────────────────────────
  describe "per-scope :authorizer" do
    let(:profiles_relation) { double("profiles") }
    let(:matched_profile) { double("OrganisationProfile") }
    let(:sessions_relation) { double("sessions", where: double(active: double(exists?: false))) }
    let(:account) do
      double("Account",
             profiles: profiles_relation,
             sessions: sessions_relation)
    end

    let(:scope_config_with_authorizer) do
      StandardId::ScopeConfig.new(:lender, {
        profile_types: ["OrganisationProfile"],
        no_profile_message: "Lender access denied.",
        authorizer: authorizer
      })
    end

    before do
      allow(mock_request).to receive(:path_parameters).and_return({ scope: :lender })
      allow(StandardId).to receive(:scope_for).with(:lender).and_return(scope_config_with_authorizer)
      allow(StandardId.config).to receive(:profile_resolver).and_return(->(_a, _t) { true })
      allow(profiles_relation).to receive(:find_by).with(profileable_type: "OrganisationProfile").and_return(matched_profile)
    end

    context "when the authorizer returns truthy" do
      let(:authorizer) { ->(account:, profile:, scope:) { true } }

      it "allows sign-in" do
        expect {
          controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
        }.not_to raise_error
      end
    end

    context "when the authorizer returns false" do
      let(:authorizer) { ->(account:, profile:, scope:) { false } }

      it "denies sign-in with the scope's no_profile_message" do
        expect {
          controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
        }.to raise_error(StandardId::AuthenticationDenied, "Lender access denied.")
      end
    end

    context "authorizer receives account, profile and scope" do
      let(:captured) { {} }
      let(:authorizer) {
        ->(account:, profile:, scope:) {
          captured[:account] = account
          captured[:profile] = profile
          captured[:scope] = scope
          true
        }
      }

      it "passes keyword args through" do
        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

        expect(captured[:account]).to eq(account)
        expect(captured[:profile]).to eq(matched_profile)
        expect(captured[:scope]).to eq(scope_config_with_authorizer)
      end
    end

    context "authorizer runs AFTER the profile_type check" do
      let(:authorizer) { ->(account:, profile:, scope:) { true } }

      it "does not run the authorizer when no profile_type matches" do
        allow(StandardId.config).to receive(:profile_resolver).and_return(->(_a, _t) { false })
        authorizer_invoked = false
        allow(scope_config_with_authorizer).to receive(:authorizer).and_return(
          ->(account:, profile:, scope:) { authorizer_invoked = true; true }
        )

        expect {
          controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
        }.to raise_error(StandardId::AuthenticationDenied)
        expect(authorizer_invoked).to eq(false)
      end
    end

    context "when the scope has an authorizer but no profile_types" do
      let(:authorizer_only_scope) do
        StandardId::ScopeConfig.new(:admin, {
          no_profile_message: "Admin access denied.",
          authorizer: authorizer
        })
      end

      before do
        allow(mock_request).to receive(:path_parameters).and_return({ scope: :admin })
        allow(StandardId).to receive(:scope_for).with(:admin).and_return(authorizer_only_scope)
      end

      context "and the authorizer returns false" do
        let(:authorizer) { ->(account:, profile:, scope:) { false } }

        it "denies the sign-in" do
          expect {
            controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
          }.to raise_error(StandardId::AuthenticationDenied, "Admin access denied.")
        end
      end

      context "and the authorizer returns truthy" do
        let(:authorizer) { ->(account:, profile:, scope:) { true } }

        it "allows the sign-in and passes nil profile" do
          captured = {}
          allow(authorizer_only_scope).to receive(:authorizer).and_return(
            ->(account:, profile:, scope:) {
              captured[:account] = account
              captured[:profile] = profile
              captured[:scope] = scope
              true
            }
          )

          controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

          expect(captured[:account]).to eq(account)
          expect(captured[:profile]).to be_nil
          expect(captured[:scope]).to eq(authorizer_only_scope)
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Back-compat — apps using the old :profile_type (singular) schema
  # ─────────────────────────────────────────────────────────────────────────
  describe "backward compatibility — legacy :profile_type schema" do
    let(:scope_config) do
      StandardId::ScopeConfig::DEPRECATOR.silence do
        StandardId::ScopeConfig.new(:borrower, {
          profile_type: "BorrowerProfile",
          after_sign_in_path: "/borrower",
          no_profile_message: "No borrower."
        })
      end
    end

    before do
      allow(mock_request).to receive(:path_parameters).and_return({ scope: :borrower })
      allow(StandardId).to receive(:scope_for).with(:borrower).and_return(scope_config)
    end

    it "still validates profile existence using the legacy single type" do
      allow(StandardId.config).to receive(:profile_resolver).and_return(->(_a, _t) { true })

      expect {
        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
      }.not_to raise_error
    end

    it "still denies when the legacy single type is missing" do
      allow(StandardId.config).to receive(:profile_resolver).and_return(->(_a, _t) { false })

      expect {
        controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })
      }.to raise_error(StandardId::AuthenticationDenied, "No borrower.")
    end

    it "still exposes :profile_type (singular) in hook context" do
      allow(StandardId.config).to receive(:profile_resolver).and_return(->(_a, _t) { true })
      received_context = nil
      allow(StandardId.config).to receive(:before_sign_in).and_return(
        ->(_account, _request, context) { received_context = context; nil }
      )

      controller.invoke_before_sign_in(account, { mechanism: "password", provider: nil })

      expect(received_context[:profile_type]).to eq("BorrowerProfile")
      expect(received_context[:profile_types]).to eq(["BorrowerProfile"])
    end

    it "still returns the legacy scope config via current_scope_config when no scope_resolver is set" do
      allow(StandardId.config).to receive(:scope_resolver).and_return(nil)
      expect(controller.current_scope_config).to eq(scope_config)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # resolve_profile_for_authorizer — direct unit coverage
  # ─────────────────────────────────────────────────────────────────────────
  describe "#resolve_profile_for_authorizer" do
    it "returns nil when the account does not respond to :profiles" do
      stranger = Object.new
      expect(controller.resolve_profile_for_authorizer(stranger, "AnyProfile")).to be_nil
    end

    it "returns nil when account.profiles does not respond to :find_by" do
      acct = double("Account", profiles: [])
      expect(controller.resolve_profile_for_authorizer(acct, "AnyProfile")).to be_nil
    end

    it "returns the matched profile from account.profiles.find_by" do
      profile = double("Profile")
      relation = double("ProfilesRelation")
      allow(relation).to receive(:find_by).with(profileable_type: "Platform").and_return(profile)
      acct = double("Account", profiles: relation)

      expect(controller.resolve_profile_for_authorizer(acct, "Platform")).to eq(profile)
    end

    it "returns nil when find_by returns nil" do
      relation = double("ProfilesRelation")
      allow(relation).to receive(:find_by).and_return(nil)
      acct = double("Account", profiles: relation)

      expect(controller.resolve_profile_for_authorizer(acct, "Platform")).to be_nil
    end

    it "swallows NoMethodError from a shape-mismatched association and returns nil" do
      relation = double("ProfilesRelation")
      allow(relation).to receive(:find_by).and_raise(NoMethodError, "undefined method `profileable_type'")
      acct = double("Account", profiles: relation)

      expect(controller.resolve_profile_for_authorizer(acct, "Platform")).to be_nil
    end

    it "lets ActiveRecord::StatementInvalid propagate rather than silently deny sign-in" do
      relation = double("ProfilesRelation")
      allow(relation).to receive(:find_by).and_raise(ActiveRecord::StatementInvalid, "connection lost")
      acct = double("Account", profiles: relation)

      expect {
        controller.resolve_profile_for_authorizer(acct, "Platform")
      }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # handle_authentication_denied — session revocation
  # ─────────────────────────────────────────────────────────────────────────
  describe "#handle_authentication_denied" do
    let(:current_session) { double("BrowserSession", present?: true) }

    context "when an active session exists" do
      before do
        allow(mock_session_manager).to receive(:current_session).and_return(current_session)
        allow(mock_session_manager).to receive(:revoke_current_session!)
      end

      it "revokes the current session before redirecting" do
        error = StandardId::AuthenticationDenied.new("Profile required")

        controller.handle_authentication_denied(error)

        expect(mock_session_manager).to have_received(:revoke_current_session!)
      end

      it "redirects to the login path with the error message as alert" do
        error = StandardId::AuthenticationDenied.new("Profile required")

        controller.handle_authentication_denied(error)

        expect(controller.redirect_options[:alert]).to eq("Profile required")
      end
    end

    context "when no session is present" do
      before do
        allow(mock_session_manager).to receive(:current_session).and_return(nil)
      end

      it "does not call revoke_current_session!" do
        allow(mock_session_manager).to receive(:revoke_current_session!)

        controller.handle_authentication_denied(StandardId::AuthenticationDenied.new("nope"))

        expect(mock_session_manager).not_to have_received(:revoke_current_session!)
      end
    end

    context "when the error has a blank message" do
      before do
        allow(mock_session_manager).to receive(:current_session).and_return(nil)
      end

      it "falls back to a generic 'Sign-in was denied' message" do
        controller.handle_authentication_denied(StandardId::AuthenticationDenied.new)

        expect(controller.redirect_options[:alert]).to eq("Sign-in was denied")
      end
    end
  end
end
