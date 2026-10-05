require "rails_helper"

# 0.45 pre-release follow-ups to the deferred social link (#363):
#
# 1. SOCIAL_ACCOUNT_LINKED is published only after the link has committed.
# 2. The web callback writes the link only after its redirect is in place.
# 3. A refused request's new account is neither adopted by, nor removed from
#    under, a concurrent login for the same email.
RSpec.describe "Social link commit", type: :request do
  let(:email) { "link-#{SecureRandom.hex(4)}@example.com" }
  let(:web_callback) { -> { http_get "/auth/callback/google", params: { state: "s", code: "c" } } }
  let(:api_callback) { -> { post "/api/oauth/callback/google", params: { code: "c" } } }

  before do
    allow(StandardId.config).to receive(:google_client_id).and_return("google_client_123")
    allow(StandardId.config).to receive(:google_client_secret).and_return("google-secret")
    allow_any_instance_of(StandardId::Web::Auth::Callback::ProvidersController)
      .to receive(:consume_oauth_request).and_return({ "params" => {}, "nonce" => nil })
  end

  def stub_google(sub, address = email)
    allow(StandardId::Providers::Google).to receive(:get_user_info).and_return(
      { user_info: { "email" => address, "email_verified" => true, "sub" => sub }, tokens: { access_token: "t" } }.with_indifferent_access
    )
  end

  def with_policy(policy)
    allow(StandardId.config).to receive(:login_method_policy).and_return(policy)
  end

  def json
    JSON.parse(response.body)
  end

  # Collects SOCIAL_ACCOUNT_LINKED, noting whether the link row was already
  # committed when the event fired.
  def capture_linked_events(subject)
    events = []
    subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_ACCOUNT_LINKED) do |event|
      events << { account: event[:account], link_written: StandardId::SocialIdentity.exists?(provider: "google", subject: subject) }
    end
    yield
    events
  ensure
    StandardId::Events.unsubscribe(subscription)
  end

  # A pre-provider-tracking identifier: linking writes the sub AND backfills
  # the provider.
  def legacy_account
    @legacy_account ||= Account.create!(name: "Legacy", email: email).tap do |account|
      StandardId::EmailIdentifier.create!(account: account, value: email, verified_at: Time.current)
    end
  end

  describe "SOCIAL_ACCOUNT_LINKED" do
    before { legacy_account }

    { "web" => :web_callback, "API" => :api_callback }.each do |label, callback|
      it "#{label}: is published once, after the link is written, for an accepted login" do
        stub_google("g-linked-#{label}")

        events = capture_linked_events("g-linked-#{label}") { instance_exec(&send(callback)) }

        expect(events.size).to eq(1)
        expect(events.first).to include(account: legacy_account, link_written: true)
      end

      it "#{label}: a subscriber that raises does not fail the committed login" do
        stub_google("g-raise-#{label}")
        subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_ACCOUNT_LINKED) { raise "subscriber boom" }
        allow(Rails.error).to receive(:report)

        begin
          instance_exec(&send(callback))
        ensure
          StandardId::Events.unsubscribe(subscription)
        end

        expect(StandardId::SocialIdentity.exists?(provider: "google", subject: "g-raise-#{label}")).to be(true)
        expect(Rails.error).to have_received(:report).with(an_instance_of(RuntimeError), hash_including(handled: true))
        if label == "API"
          expect(response).to have_http_status(:ok)
          expect(json).to include("access_token")
        else
          expect(response).to have_http_status(:redirect)
          expect(response.location).not_to include("/login")
        end
      end

      it "#{label}: is not published when the policy refuses the login" do
        stub_google("g-refused-#{label}")
        with_policy(->(**) { false })

        events = capture_linked_events("g-refused-#{label}") { instance_exec(&send(callback)) }

        expect(events).to be_empty
        expect(StandardId::SocialIdentity.where(subject: "g-refused-#{label}")).to be_empty
      end
    end

    it "web: is not published when before_sign_in refuses the login" do
      stub_google("g-hook")
      allow(StandardId.config).to receive(:before_sign_in).and_return(->(_a, _r, _c) { { error: "Nope" } })

      expect(capture_linked_events("g-hook") { web_callback.call }).to be_empty
      expect(response).to redirect_to("/login")
    end

    it "API: is not published when a scope check refuses the login" do
      allow(StandardId.config.social).to receive(:available_scopes).and_return(["openid"])
      stub_google("g-scope")

      expect(capture_linked_events("g-scope") { post "/api/oauth/callback/google", params: { code: "c", scope: "admin" } }).to be_empty
      expect(response).to have_http_status(:bad_request)
    end

    # The backfill and the (provider, sub) insert commit together: when the
    # insert fails, the backfill is rolled back with it. (Codex on #363:
    # "Keep rollback state until the link fully commits".)
    it "is not published, and the provider backfill is rolled back, when writing the link fails" do
      stub_google("g-insert-fails")
      allow(StandardId::SocialIdentity).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "insert failed")

      events = capture_linked_events("g-insert-fails") do
        expect { api_callback.call }.to raise_error(ActiveRecord::StatementInvalid)
      end

      expect(events).to be_empty
      expect(StandardId::EmailIdentifier.find_by(value: email).provider).to be_nil
    end
  end

  # A concurrent callback for the same (provider, sub) commits its link to a
  # DIFFERENT account before this request's SELECT, so the
  # existing row comes back without a unique violation. It must be refused
  # like the RecordNotUnique path, not adopted.
  describe "a (provider, sub) row committed concurrently for another account" do
    before { legacy_account }

    def other_account
      @other_account ||= Account.create!(name: "Other", email: "other-#{SecureRandom.hex(4)}@example.com").tap do |account|
        StandardId::EmailIdentifier.create!(account: account, value: account.email, verified_at: Time.current)
      end
    end

    def commit_rival_link(subject)
      rival = StandardId::Identifier.find_by!(account_id: other_account.id)
      ->(*) {
        StandardId::SocialIdentity.create!(provider: "google", subject: subject, account: other_account, identifier: rival)
        nil
      }
    end

    # SOCIAL_LINK_BLOCKED (reason :subject_conflict) once, and never the
    # infrastructure-only SOCIAL_AUTH_FAILED.
    def capture_conflict_events
      blocked = []
      failed = []
      subscriptions = [
        StandardId::Events.subscribe(StandardId::Events::SOCIAL_LINK_BLOCKED) { |event| blocked << event },
        StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_FAILED) { |event| failed << event }
      ]
      yield
      [blocked, failed]
    ensure
      subscriptions&.each { |subscription| StandardId::Events.unsubscribe(subscription) }
    end

    def expect_conflict_reported(blocked, failed, reason: :subject_conflict)
      expect(failed).to be_empty
      expect(blocked.size).to eq(1)
      expect(blocked.first[:reason]).to eq(reason)
      expect(blocked.first[:email]).to eq(email)
      expect(blocked.first[:account]).to eq(legacy_account)
      expect(blocked.first[:identifier]).to eq(StandardId::Identifier.find_by!(account_id: legacy_account.id))
      expect(blocked.first[:provider].provider_name).to eq("google")
    end

    it "web: fails with a retryable error and leaves the rival link and no session on the matched account" do
      stub_google("g-rival-web")
      allow(StandardId.config).to receive(:before_sign_in).and_return(commit_rival_link("g-rival-web"))

      blocked, failed = capture_conflict_events { web_callback.call }

      expect_conflict_reported(blocked, failed)
      expect(flash[:alert]).to include(StandardId::SocialAuthentication::SOCIAL_RETRY_MESSAGE)

      expect(response).to redirect_to("/login")
      expect(StandardId::SocialIdentity.find_by(subject: "g-rival-web").account_id).to eq(other_account.id)
      expect(StandardId::Session.where(account_id: legacy_account.id).active).to be_empty
      expect(StandardId::Identifier.find_by!(account_id: legacy_account.id).provider).to be_nil
    end

    it "API: answers invalid_grant and revokes what it issued for the matched account" do
      stub_google("g-rival-api")
      with_policy(->(account:) {
        commit_rival_link("g-rival-api").call if account.id == legacy_account.id
        true
      })

      blocked, failed = capture_conflict_events { api_callback.call }

      expect_conflict_reported(blocked, failed)
      expect(response).to have_http_status(:bad_request)
      expect(json).to include("error" => "invalid_grant")
      expect(StandardId::SocialIdentity.find_by(subject: "g-rival-api").account_id).to eq(other_account.id)
      expect(StandardId::RefreshToken.active.where(account_id: legacy_account.id)).to be_empty
    end
  end

  # The rival row is committed by a concurrent login AFTER this login's
  # SELECT found nothing. Driven through the real record_social_identity!:
  #   - :before_validation — the rival appears right after the SELECT, so the
  #     model's uniqueness validations raise RecordInvalid;
  #   - :before_insert — the rival appears after validation, so the unique
  #     index raises RecordNotUnique.
  # Rivals: the same sub for ANOTHER account (:subject_conflict), this
  # identifier under ANOTHER sub (:subject_mismatch), or the same sub for
  # THIS account (adopted, the login succeeds).
  #
  # The rival is written on the request's own connection inside the link
  # transaction (outside the INSERT's savepoint), so it is rolled back with
  # the refused link; assertions are about what the login did.
  describe "a rival link committed between this login's SELECT and INSERT" do
    before { legacy_account }

    def other_account
      @other_account ||= Account.create!(name: "Other", email: "other-#{SecureRandom.hex(4)}@example.com").tap do |account|
        StandardId::EmailIdentifier.create!(account: account, value: account.email, verified_at: Time.current)
      end
    end

    def rival_attributes(kind, sub)
      legacy_identifier = StandardId::Identifier.find_by!(account_id: legacy_account.id)
      base = { provider: "google", created_at: Time.current, updated_at: Time.current }
      case kind
      when :other_account
        base.merge(subject: sub, account_id: other_account.id, identifier_id: StandardId::Identifier.find_by!(account_id: other_account.id).id)
      when :other_sub
        base.merge(subject: "#{sub}-theirs", account_id: legacy_account.id, identifier_id: legacy_identifier.id)
      when :same_account
        base.merge(subject: sub, account_id: legacy_account.id, identifier_id: legacy_identifier.id)
      end
    end

    def arrange_race(at:, rival:)
      rival = rival.merge(id: SecureRandom.uuid) if StandardId::SocialIdentity.columns_hash["id"]&.type == :string
      insert_rival = -> { StandardId::SocialIdentity.insert_all!([rival]) }
      case at
      when :before_validation
        # The SELECT (the class-level find_by on provider + subject) misses;
        # the rival commits straight after it, so the uniqueness
        # validations see it.
        select_then { insert_rival.call }
      when :before_insert
        # The rival commits after this login's validations have passed: the
        # uniqueness validators see no rival (they are skipped here), so the
        # unique index is what refuses the INSERT. The rival is written
        # before the savepoint opens, so rolling the savepoint back keeps it.
        select_then { insert_rival.call }
        allow_any_instance_of(ActiveRecord::Validations::UniquenessValidator).to receive(:validate_each)
      end
    end

    def select_then(&after_select)
      selected = false
      allow(StandardId::SocialIdentity).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
        result = original.call(*args, **kwargs)
        if !selected && args.first.is_a?(Hash) && args.first.keys.map(&:to_sym).sort == %i[provider subject]
          selected = true
          after_select.call
        end
        result
      end
    end

    def capture_link_events
      blocked = []
      failed = []
      linked = []
      subscriptions = [
        StandardId::Events.subscribe(StandardId::Events::SOCIAL_LINK_BLOCKED) { |event| blocked << event },
        StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_FAILED) { |event| failed << event },
        StandardId::Events.subscribe(StandardId::Events::SOCIAL_ACCOUNT_LINKED) { |event| linked << event }
      ]
      yield
      [blocked, failed, linked]
    ensure
      subscriptions&.each { |subscription| StandardId::Events.unsubscribe(subscription) }
    end

    %i[before_validation before_insert].each do |at|
      { "web" => :web_callback, "API" => :api_callback }.each do |label, callback|
        { other_account: :subject_conflict, other_sub: :subject_mismatch }.each do |kind, reason|
          it "#{label}, rival #{kind} #{at}: SOCIAL_LINK_BLOCKED #{reason.inspect}, no SOCIAL_AUTH_FAILED, retryable" do
            sub = "g-#{at}-#{kind}-#{label}"
            stub_google(sub)
            arrange_race(at: at, rival: rival_attributes(kind, sub))

            blocked, failed, linked = capture_link_events { instance_exec(&send(callback)) }

            expect(failed).to be_empty
            expect(linked).to be_empty
            expect(blocked.size).to eq(1)
            expect(blocked.first[:reason]).to eq(reason)
            expect(blocked.first[:email]).to eq(email)
            expect(blocked.first[:account]).to eq(legacy_account)
            expect(StandardId::SocialIdentity.where(subject: sub, account_id: legacy_account.id)).to be_empty
            expect(StandardId::Identifier.find_by!(account_id: legacy_account.id).provider).to be_nil
            if label == "web"
              expect(response).to redirect_to("/login")
              expect(flash[:alert]).to include(StandardId::SocialAuthentication::SOCIAL_RETRY_MESSAGE)
              expect(StandardId::Session.where(account_id: legacy_account.id).active).to be_empty
            else
              expect(response).to have_http_status(:bad_request)
              expect(json).to include("error" => "invalid_grant")
              expect(StandardId::RefreshToken.active.where(account_id: legacy_account.id)).to be_empty
            end
          end
        end

        it "#{label}, rival for the same account #{at}: adopts it and signs in" do
          sub = "g-#{at}-same-#{label}"
          stub_google(sub)
          arrange_race(at: at, rival: rival_attributes(:same_account, sub))

          blocked, failed, linked = capture_link_events { instance_exec(&send(callback)) }

          expect(blocked).to be_empty
          expect(failed).to be_empty
          expect(linked.size).to eq(1)
          expect(StandardId::SocialIdentity.where(subject: sub, account_id: legacy_account.id).count).to eq(1)
          if label == "web"
            expect(response.location).not_to end_with("/login")
          else
            expect(response).to have_http_status(:ok)
          end
        end
      end
    end

    # MySQL/InnoDB REPEATABLE READ (Codex on #365): every plain SELECT in the
    # link transaction reads the snapshot taken by its first plain read, so
    # a rival committed after this login's SELECT stays invisible to plain
    # reads — the uniqueness validations pass, the unique index refuses the
    # INSERT, and only a locking read (SELECT ... FOR UPDATE) sees the rival.
    # SQLite has no such snapshot, so it is emulated: once the rival has
    # committed, plain reads of standard_id_social_identities leave it out;
    # reads on a relation with a lock clause see it.
    def under_repeatable_read(rival)
      rival = rival.merge(id: SecureRandom.uuid) if StandardId::SocialIdentity.columns_hash["id"]&.type == :string
      hidden_ids = []
      hidden = ->(record) { record && hidden_ids.include?(record.id) }

      allow(StandardId::SocialIdentity).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
        result = original.call(*args, **kwargs)
        if hidden_ids.empty? && args.first.is_a?(Hash) && args.first.keys.map(&:to_sym).sort == %i[provider subject]
          StandardId::SocialIdentity.insert_all!([rival])
          hidden_ids.concat(StandardId::SocialIdentity.where(rival.slice(:provider, :subject)).pluck(:id))
        end
        hidden.call(result) ? nil : result
      end

      relation_class = StandardId::SocialIdentity.all.class
      allow_any_instance_of(relation_class).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
        result = original.call(*args, **kwargs)
        original.receiver.lock_value || !hidden.call(result) ? result : nil
      end
      allow_any_instance_of(relation_class).to receive(:exists?).and_wrap_original do |original, *args, **kwargs|
        next original.call(*args, **kwargs) if original.receiver.lock_value || hidden_ids.empty? || args.any? || kwargs.any?

        (original.receiver.pluck(:id) - hidden_ids).any?
      end
    end

    { "web" => :web_callback, "API" => :api_callback }.each do |label, callback|
      { other_account: :subject_conflict, other_sub: :subject_mismatch }.each do |kind, reason|
        it "#{label}, rival #{kind} under REPEATABLE READ: classified by a locking read, not a 500" do
          sub = "g-rr-#{kind}-#{label}"
          stub_google(sub)
          under_repeatable_read(rival_attributes(kind, sub))

          blocked, failed, linked = capture_link_events { instance_exec(&send(callback)) }

          expect(failed).to be_empty
          expect(linked).to be_empty
          expect(blocked.map { |event| event[:reason] }).to eq([reason])
          expect(StandardId::SocialIdentity.where(subject: sub, account_id: legacy_account.id)).to be_empty
          if label == "web"
            expect(response).to redirect_to("/login")
            expect(flash[:alert]).to include(StandardId::SocialAuthentication::SOCIAL_RETRY_MESSAGE)
          else
            expect(response).to have_http_status(:bad_request)
            expect(json).to include("error" => "invalid_grant")
          end
        end
      end

      it "#{label}, rival for the same account under REPEATABLE READ: adopts it and signs in" do
        sub = "g-rr-same-#{label}"
        stub_google(sub)
        under_repeatable_read(rival_attributes(:same_account, sub))

        blocked, failed, linked = capture_link_events { instance_exec(&send(callback)) }

        expect(blocked).to be_empty
        expect(failed).to be_empty
        expect(linked.size).to eq(1)
        if label == "web"
          expect(response.location).not_to end_with("/login")
        else
          expect(response).to have_http_status(:ok)
        end
      end
    end

    it "re-raises a RecordInvalid that is not a lost race" do
      stub_google("g-invalid")
      # A validation failure that is not a uniqueness race (provider blank).
      allow_any_instance_of(StandardId::SocialIdentity).to receive(:provider).and_return(nil)

      blocked, failed, = capture_link_events { api_callback.call }

      # Propagated, not classified: the test env's show_exceptions renders
      # RecordInvalid as Rails' 422 (rescue_responses) instead of raising it.
      expect(response).to have_http_status(:unprocessable_content)
      expect(blocked).to be_empty
      expect(failed).to be_empty
      expect(StandardId::SocialIdentity.where(subject: "g-invalid")).to be_empty
    end
  end

  describe "web: the link is written only after the redirect" do
    before { legacy_account }

    it "leaves no link, no backfill and no live session when the redirect itself raises" do
      stub_google("g-bad-redirect")
      # A cross-host URL that is not on allowed_redirect_url_prefixes:
      # redirect_to refuses it (open-redirect protection; the dummy app runs
      # Rails' default action_on_open_redirect = :raise).
      allow(StandardId.config).to receive(:after_sign_in).and_return(->(_a, _r, _c) { "https://elsewhere.example/landing" })

      events = capture_linked_events("g-bad-redirect") do
        expect { web_callback.call }.to raise_error(ActionController::Redirecting::UnsafeRedirectError)
      end

      expect(events).to be_empty
      expect(StandardId::SocialIdentity.where(subject: "g-bad-redirect")).to be_empty
      expect(StandardId::EmailIdentifier.find_by(value: email).provider).to be_nil
      expect(StandardId::BrowserSession.where(account_id: legacy_account.id).active).to be_empty
    end
  end

  # Request A creates a new account, then is refused and removes it
  # (AccountCleanup.destroy_newly_created!). Request B, for the same email,
  # finds that account by email in the meantime.
  describe "a refused request's new account and a concurrent login for the same email" do
    let(:new_email) { "new-#{email}" }

    # B signs in to A's account before A's refusal removes it: the account
    # has been adopted and is kept. Simulated by B's session appearing from
    # inside A's policy check, the point at which A is about to be refused.
    { "web" => :web_callback, "API" => :api_callback }.each do |label, callback|
      it "#{label}: A keeps the account when B has already signed in to it" do
        stub_google("g-a-#{label}", new_email)
        b_session = nil
        with_policy(->(account:) {
          b_session = StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.2", user_agent: "B", expires_at: 1.hour.from_now)
          false
        })

        instance_exec(&send(callback))

        expect(b_session).to be_present
        expect(Account.exists?(b_session.account_id)).to be(true)
        expect(b_session.reload.revoked_at).to be_nil
        expect(StandardId::EmailIdentifier.find_by(value: new_email)).to be_present
      end
    end

    # A's own tokens never count as a concurrent login: here the grant raises
    # after it wrote them, so no token response comes back, and the callback
    # revokes them from the flow before the cleanup checks for adoption.
    it "API: A still removes its account when the grant fails after issuing tokens" do
      stub_google("g-a-issued", new_email)
      subscription = StandardId::Events.subscribe(StandardId::Events::OAUTH_TOKEN_ISSUED) { |_e| raise "subscriber bug" }

      expect {
        expect { api_callback.call }.to raise_error(RuntimeError, "subscriber bug")
      }.not_to change { [Account.count, StandardId::Identifier.count, StandardId::RefreshToken.count, StandardId::Session.count] }
    ensure
      StandardId::Events.unsubscribe(subscription)
    end

    # A's removal runs first (B has no session yet): B must not end up
    # signed in to, or linked to, the removed account; it fails cleanly and
    # a retry creates a fresh account.
    def doomed_account
      @doomed_account ||= Account.create!(name: "Doomed", email: new_email).tap do |account|
        StandardId::EmailIdentifier.create!(account: account, value: new_email, provider: "google", verified_at: Time.current)
      end
    end

    it "web: B fails with a retryable error, and a retry signs in to a fresh account" do
      stub_google("g-b-web", new_email)
      doomed = doomed_account
      allow(StandardId.config).to receive(:before_sign_in).and_return(->(account, _r, _c) {
        StandardId::AccountCleanup.destroy_newly_created!(account) if account.id == doomed.id
        nil
      })

      web_callback.call

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to include("Please try again")
      expect(Account.exists?(doomed.id)).to be(false)
      expect(StandardId::SocialIdentity.where(subject: "g-b-web")).to be_empty

      web_callback.call # the retry

      fresh_id = StandardId::EmailIdentifier.find_by(value: new_email).account_id
      expect(fresh_id).not_to eq(doomed.id)
      expect(response.location).not_to end_with("/login")
      expect(StandardId::SocialIdentity.find_by(subject: "g-b-web").account_id).to eq(fresh_id)
    end

    it "API: B fails with invalid_grant, and a retry gets tokens for a fresh account" do
      stub_google("g-b-api", new_email)
      doomed = doomed_account
      with_policy(->(account:) {
        StandardId::AccountCleanup.destroy_newly_created!(account) if account.id == doomed.id
        true
      })

      api_callback.call

      expect(response).to have_http_status(:bad_request)
      expect(json).to include("error" => "invalid_grant", "error_description" => StandardId::SocialAuthentication::SOCIAL_RETRY_MESSAGE)
      expect(Account.exists?(doomed.id)).to be(false)
      expect(StandardId::SocialIdentity.where(subject: "g-b-api")).to be_empty

      api_callback.call # the retry

      expect(response).to have_http_status(:ok)
      fresh_id = StandardId::EmailIdentifier.find_by(value: new_email).account_id
      expect(fresh_id).not_to eq(doomed.id)
      expect(StandardId::SocialIdentity.find_by(subject: "g-b-api").account_id).to eq(fresh_id)
    end

    # A is refused while B has already signed in to A's account, so A keeps
    # it (above). B then fails as well (Codex on #364): B's discard path has
    # newly_created == false, so without coordination nobody removes the
    # account and it is orphaned, blocking a later signup for the address.
    # A remembers the credentials it kept the account for; B's failure
    # reclaims it. Simulated by running A's cleanup from inside B's request
    # once B's session / tokens exist (a SOCIAL_AUTH_COMPLETED subscriber),
    # then failing B.
    describe "the login A kept its account for fails as well" do
      let(:cache) { ActiveSupport::Cache::MemoryStore.new }

      before { allow(StandardId).to receive(:cache_store).and_return(cache) }

      # Runs A's refusal cleanup for the doomed account from inside B's
      # request, then lets B fail with `failure` (or succeed when nil).
      def refuse_a_during_b(doomed, failure: nil)
        kept = []
        subscription = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_COMPLETED) do |event|
          next unless event[:account].id == doomed.id

          kept << !StandardId::AccountCleanup.destroy_newly_created!(event[:account])
          raise failure if failure
        end
        yield
        kept
      ensure
        StandardId::Events.unsubscribe(subscription)
      end

      def account_footprint(account)
        [
          Account.exists?(account.id),
          StandardId::Identifier.where(account_id: account.id).exists?,
          StandardId::Session.where(account_id: account.id).exists?,
          StandardId::RefreshToken.where(account_id: account.id).exists?
        ]
      end

      it "web: B raises after signing in, and the account is removed" do
        stub_google("g-b-fails-web", new_email)
        doomed = doomed_account

        kept = refuse_a_during_b(doomed, failure: "B failed") do
          expect { web_callback.call }.to raise_error(RuntimeError, "B failed")
        end

        expect(kept).to eq([true])
        expect(account_footprint(doomed)).to eq([false, false, false, false])
        expect(StandardId::SocialIdentity.where(subject: "g-b-fails-web")).to be_empty
      end

      it "web: B is denied by after_sign_in, and the account is removed" do
        stub_google("g-b-denied-web", new_email)
        doomed = doomed_account
        allow(StandardId.config).to receive(:after_sign_in).and_return(->(_a, _r, _c) { raise StandardId::AuthenticationDenied, "Nope" })

        kept = refuse_a_during_b(doomed) { web_callback.call }

        expect(kept).to eq([true])
        expect(response).to redirect_to("/login")
        expect(account_footprint(doomed)).to eq([false, false, false, false])
      end

      it "API: B fails after its tokens were issued, and the account is removed" do
        stub_google("g-b-fails-api", new_email)
        doomed = doomed_account

        kept = refuse_a_during_b(doomed, failure: "B failed") do
          expect { api_callback.call }.to raise_error(RuntimeError, "B failed")
        end

        expect(kept).to eq([true])
        expect(account_footprint(doomed)).to eq([false, false, false, false])
      end

      it "web: the account stays when another login still uses it" do
        stub_google("g-b-other-web", new_email)
        doomed = doomed_account
        # C signs in to the account too, while B is in flight.
        c_session = nil
        allow(StandardId.config).to receive(:before_sign_in).and_return(->(account, _r, _c) {
          c_session = StandardId::BrowserSession.create!(account: account, ip_address: "127.0.0.3", user_agent: "C", expires_at: 1.hour.from_now)
          nil
        })

        kept = refuse_a_during_b(doomed, failure: "B failed") do
          expect { web_callback.call }.to raise_error(RuntimeError, "B failed")
        end

        expect(kept).to eq([true])
        expect(Account.exists?(doomed.id)).to be(true)
        expect(c_session.reload.revoked_at).to be_nil
      end

      # B succeeds: the account is B's now. A later login on it that fails
      # did not issue any credential A kept the account for, so it never
      # removes the account.
      it "web: once B has succeeded, a later failing login leaves the account alone" do
        stub_google("g-b-succeeds-web", new_email)
        doomed = doomed_account

        kept = refuse_a_during_b(doomed) { web_callback.call }
        expect(kept).to eq([true])
        expect(response.location).not_to end_with("/login")
        StandardId::Session.where(account_id: doomed.id).find_each { |session| session.revoke!(reason: "logout") }

        refuse_later = StandardId::Events.subscribe(StandardId::Events::SOCIAL_AUTH_COMPLETED) { |_e| raise "later failure" }
        begin
          expect { web_callback.call }.to raise_error(RuntimeError, "later failure")
        ensure
          StandardId::Events.unsubscribe(refuse_later)
        end

        expect(Account.exists?(doomed.id)).to be(true)
        expect(StandardId::SocialIdentity.find_by(subject: "g-b-succeeds-web").account_id).to eq(doomed.id)
      end
    end

    # The commit itself re-checks the account under the row lock: if the
    # account is removed after B's session exists (possible only where the
    # host has no foreign key on sessions.account_id), the link is not
    # written and B's redirect is replaced by /login.
    it "web: B's commit refuses an account removed after its session was created" do
      stub_google("g-b-commit", new_email)
      doomed = doomed_account
      allow(StandardId::AccountCleanup).to receive(:adopted?).and_return(false) # force the removal through
      allow(StandardId.config).to receive(:after_sign_in).and_return(->(account, _r, _c) {
        StandardId::AccountCleanup.destroy_newly_created!(account)
        nil
      })

      events = capture_linked_events("g-b-commit") { web_callback.call }

      expect(response).to redirect_to("/login")
      expect(flash[:alert]).to include("Please try again")
      expect(flash[:notice]).to be_nil
      expect(events).to be_empty
      expect(Account.exists?(doomed.id)).to be(false)
      expect(StandardId::SocialIdentity.where(subject: "g-b-commit")).to be_empty
    end
  end
end
