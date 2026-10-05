module StandardId
  module SocialAuthentication
    extend ActiveSupport::Concern

    included do
      prepend_before_action :prepare_provider
    end

    VALID_LINK_STRATEGIES = %i[strict trust_provider].freeze

    private

    attr_reader :provider

    def prepare_provider
      @provider = StandardId::ProviderRegistry.get(params[:provider])
    rescue StandardId::ProviderRegistry::ProviderNotFoundError => e
      raise StandardId::InvalidRequestError, e.message
    end

    # `callback_iss` is the callback's RFC 9207 `iss` parameter (a String
    # only; anything else is dropped), for providers that defend against
    # authorization-server mix-up. `code_verifier` is passed only by the web
    # callback, from the server-held flow state, for providers that opt in to
    # core-managed PKCE (Providers::Base.supports_pkce?). Nil values are not
    # passed, so a provider that ignores both sees no change.
    def get_user_info_from_provider(redirect_uri: nil, nonce: nil, code_verifier: nil, flow: :web)
      provider_params = {
        code: params[:code],
        id_token: params[:id_token],
        access_token: params[:access_token],
        redirect_uri:,
        nonce:,
        callback_iss: callback_iss_param,
        code_verifier:
      }

      resolved_params = provider.resolve_params(provider_params, context: { flow: flow })
      provider.get_user_info(**resolved_params.compact)
    end

    def callback_iss_param
      iss = params[:iss]
      iss.is_a?(String) && iss.present? ? iss : nil
    end

    # Resolves the account for a social login, in this order:
    #
    # 1. (provider, sub) matches a StandardId::SocialIdentity → that account.
    #    The provider's stable subject id is authoritative; the email it
    #    reports is not consulted.
    # 2. The email matches an existing EmailIdentifier → link to that account,
    #    but only when
    #      - the link_strategy allows it (validate_social_link!; under :strict a
    #        provider that is trusted_for_linking? may link across providers
    #        to a verified identifier),
    #      - the identifier is not already linked to a DIFFERENT sub from this
    #        provider (possible takeover), and
    #      - the provider reports the email as verified. Without that, the
    #        token proves nothing about who owns the address — under
    #        :trust_provider, or for a pre-provider-tracking identifier, any
    #        provider token for the address would otherwise take the account.
    #    A successful link stores the sub, so step 1 matches next time.
    # 3. Otherwise create a new account (unchanged) and store the sub.
    #
    # Each refusal raises StandardId::SocialLinkError (with a `reason`) after
    # emitting SOCIAL_LINK_BLOCKED; a duplicate account is never created.
    def find_or_create_account_from_social(raw_social_info)
      social_info = raw_social_info.to_h.with_indifferent_access
      email = social_info[:email]
      raise StandardId::InvalidRequestError, "No email provided by #{provider.provider_name}" if email.blank?

      emit_social_user_info_fetched(provider, social_info, email)

      subject = social_subject(social_info)
      social_identity = find_social_identity(subject)
      if social_identity
        emit_social_account_linked(social_identity.account, provider, social_identity.identifier)
        return social_identity.account
      end

      identifier = StandardId::EmailIdentifier.includes(:account).find_by(value: email)

      if identifier.present?
        validate_social_link!(identifier, provider)
        validate_social_subject!(identifier, provider, subject)
        validate_social_email_verified!(identifier, provider, social_info)
        # SOCIAL_ACCOUNT_LINKED is published by commit_social_link!, once the
        # link has been written — never for a staged link that is dropped.
        stage_social_link!(identifier, subject, backfill_provider: identifier.provider.nil?, emit_linked: true)
        identifier.account
      else
        account = build_account_from_social(social_info)
        identifier = StandardId::EmailIdentifier.create!(
          account: account,
          value: email,
          provider: provider.provider_name
        )
        identifier.verify! if identifier.respond_to?(:verify!) && social_email_verified?(social_info)
        stage_social_link!(identifier, subject, backfill_provider: false)
        emit_social_account_created(account, provider, social_info)
        account
      end
    end

    def validate_social_link!(identifier, provider)
      strategy = StandardId.config.social.link_strategy

      unless VALID_LINK_STRATEGIES.include?(strategy)
        raise ArgumentError, "Invalid social.link_strategy: #{strategy.inspect}. " \
          "Must be one of: #{VALID_LINK_STRATEGIES.map(&:inspect).join(', ')}"
      end

      return if strategy == :trust_provider
      # nil provider means the identifier predates provider tracking — allow
      # through since we can't retroactively determine its origin. The
      # email_verified check (validate_social_email_verified!) still applies.
      return if identifier.provider.nil?
      return if identifier.provider == provider.provider_name
      return if account_has_social_identifier_from?(identifier.account, provider)
      return if trusted_cross_provider_link?(identifier, provider)

      refuse_social_link!(identifier, provider, :link_required)
    end

    # The provider opted in via Providers::Base.trusted_for_linking? (only the
    # org's own IdP, whose email claims the org verifies, should) AND the
    # existing identifier's address is itself verified. This only lifts the
    # :strict cross-provider refusal: validate_social_subject! and
    # validate_social_email_verified! still run after it, so an unverified
    # provider email or a different sub is refused exactly as before.
    #
    # The verified-identifier requirement closes pre-account hijacking: an
    # account someone registered for an address they never proved must not
    # be handed to the address's real owner arriving via the trusted IdP
    # (the registrant would keep their own way in).
    def trusted_cross_provider_link?(identifier, provider)
      return false unless provider.respond_to?(:trusted_for_linking?)
      return false unless provider.trusted_for_linking? == true

      identifier.respond_to?(:verified?) && identifier.verified?
    end

    # The identifier is already linked to another subject from this provider:
    # a second provider account is claiming the same address.
    def validate_social_subject!(identifier, provider, subject)
      return if subject.nil?
      return unless StandardId::SocialIdentity.available?

      linked = StandardId::SocialIdentity.where(identifier_id: identifier.id, provider: provider.provider_name)
      return unless linked.where.not(subject: subject).exists?

      refuse_social_link!(identifier, provider, :subject_mismatch)
    end

    # Linking a login to an EXISTING account by email needs the provider to
    # vouch for the address, under either link_strategy.
    def validate_social_email_verified!(identifier, provider, social_info)
      return if social_email_verified?(social_info)

      refuse_social_link!(identifier, provider, :email_unverified)
    end

    def refuse_social_link!(identifier, provider, reason)
      emit_social_link_blocked(identifier, provider, reason)
      raise StandardId::SocialLinkError.new(
        email: identifier.value,
        provider_name: provider.provider_name,
        reason: reason
      )
    end

    # The provider's stable subject id (OIDC `sub`), or nil when the provider
    # reports none.
    def social_subject(social_info)
      social_info[:sub].presence&.to_s
    end

    # Strict: only boolean true or the string "true" (any case) count. Apple
    # sends `email_verified` as the string "true"; Google's tokeninfo endpoint
    # does too. Google's OAuth2 v2 userinfo endpoint names the claim
    # `verified_email` (standard_id-google <= 0.5.0 passes it through as-is),
    # so it is accepted as a fallback.
    def social_email_verified?(social_info)
      value = social_info.key?(:email_verified) ? social_info[:email_verified] : social_info[:verified_email]
      value.to_s.strip.casecmp?("true")
    end

    def find_social_identity(subject)
      return nil if subject.nil?
      return nil unless social_identities_available?

      StandardId::SocialIdentity.includes(:account, :identifier).find_by(provider: provider.provider_name, subject: subject)
    end

    # Writes the (provider, sub) row inside its own savepoint (it runs inside
    # commit_social_link!'s transaction; on PostgreSQL a failed INSERT would
    # otherwise abort it).
    #
    # Find-then-insert is spelled out rather than left to find_or_create_by!,
    # because a concurrent login can commit a rival row at any point in it and
    # each point surfaces differently: before the SELECT (the row is found),
    # between the SELECT and validation (the uniqueness validations raise
    # RecordInvalid), or between validation and the INSERT (the unique index
    # raises RecordNotUnique; find_or_create_by! would turn an
    # (identifier, provider) collision into RecordNotFound, and return a
    # (provider, sub) winner for ANY account). Every one of them is classified
    # by classify_social_link_race!.
    #
    # A row found by the first lookup can be removed again (e.g. by a
    # concurrent account cleanup) before classify_social_link_race! re-reads
    # it. The (provider, sub) is then free, so the insert goes ahead: returning
    # instead would let commit_social_link! backfill the provider and publish
    # SOCIAL_ACCOUNT_LINKED for a link no row records.
    def record_social_identity!(identifier, subject)
      return if subject.nil?
      return unless social_identities_available?

      attributes = { provider: provider.provider_name, subject: subject }
      if StandardId::SocialIdentity.find_by(attributes)
        winner = classify_social_link_race!(identifier, subject)
        return winner if winner
      end

      StandardId::SocialIdentity.transaction(requires_new: true) do
        StandardId::SocialIdentity.create!(attributes.merge(account: identifier.account, identifier: identifier))
      end
    rescue ActiveRecord::RecordNotUnique
      classify_social_link_race!(identifier, subject) || raise
    rescue ActiveRecord::RecordInvalid => e
      raise unless social_link_race_invalid?(e.record)

      classify_social_link_race!(identifier, subject) || insert_past_stale_uniqueness!(e.record, identifier, subject)
    end

    # The uniqueness validations said `taken`, but the locking re-read in
    # classify_social_link_race! finds no rival: the validations read a stale
    # snapshot. Under MySQL/InnoDB REPEATABLE READ they read the transaction's
    # snapshot, which still holds a row a concurrent cleanup has since removed
    # (the vanished-row case above), and every later validation would say
    # `taken` again. Every other validation passed (social_link_race_invalid?),
    # and both uniqueness rules are backed by unique indexes, so insert once
    # without validating and let the indexes decide; a rival that commits in
    # the meantime surfaces as RecordNotUnique and is classified as usual.
    def insert_past_stale_uniqueness!(record, identifier, subject)
      StandardId::SocialIdentity.transaction(requires_new: true) { record.save!(validate: false) }
      record
    rescue ActiveRecord::RecordNotUnique
      classify_social_link_race!(identifier, subject) || raise
    end

    # A RecordInvalid that is only the uniqueness validations losing a race.
    # Anything else (a missing account, a host validation) is a real error.
    def social_link_race_invalid?(record)
      details = record&.errors&.details
      return false if details.blank?

      details.all? do |attribute, errors|
        %i[subject identifier_id].include?(attribute) && errors.all? { |error| error[:error] == :taken }
      end
    end

    # Another login has linked first. Returns the winning row when it links
    # this (provider, sub) to the same account (adopt it); raises
    # SocialLinkConflictError when it links this sub to ANOTHER account
    # (:subject_conflict) or this identifier to this provider under ANOTHER
    # sub (:subject_mismatch); returns nil when no rival is found (it was
    # removed again), so the caller re-raises the original error.
    #
    # Both lookups are locking reads (SELECT ... FOR UPDATE). They run inside
    # commit_social_link!'s transaction, and under MySQL/InnoDB's default
    # REPEATABLE READ a plain SELECT there reads the snapshot taken by the
    # transaction's first plain read (record_social_identity!'s own lookup),
    # which predates the rival that just made the INSERT fail: the rival
    # would be invisible, the race unclassified, and the login a 500 with no
    # SOCIAL_LINK_BLOCKED. A locking read always reads the latest committed
    # row. Under PostgreSQL's READ COMMITTED (and on SQLite, where `lock` is
    # a no-op) a plain read already saw it; the lock only holds the rival row
    # until this transaction ends.
    def classify_social_link_race!(identifier, subject)
      winner = StandardId::SocialIdentity.lock.find_by(provider: provider.provider_name, subject: subject)
      if winner
        return winner if winner.account_id == identifier.account_id

        raise StandardId::SocialLinkConflictError.new(SOCIAL_RETRY_MESSAGE, identifier: identifier, reason: :subject_conflict)
      end

      other_sub = StandardId::SocialIdentity.where(identifier_id: identifier.id, provider: provider.provider_name).where.not(subject: subject)
      return nil unless other_sub.lock.exists?

      raise StandardId::SocialLinkConflictError.new(SOCIAL_RETRY_MESSAGE, identifier: identifier, reason: :subject_mismatch)
    end

    # The (provider, sub) link and the provider backfill are STAGED, not
    # written, by find_or_create_account_from_social when the caller defers
    # them (the web and API callbacks do), and written by commit_social_link!
    # only once the login has been accepted. A rejected login therefore never
    # writes a link, so rejecting it never has to delete one — and cannot
    # delete a row a concurrent, successful callback for the same
    # (provider, sub) has created or adopted in the meantime.
    #
    # Callers that do not defer (the default, e.g. host code calling
    # find_or_create_account_from_social directly) get the link written
    # immediately, as before.
    def stage_social_link!(identifier, subject, backfill_provider:, emit_linked: false)
      @pending_social_link = {
        identifier: identifier,
        subject: subject,
        backfill_provider: backfill_provider,
        emit_linked: emit_linked
      }
      commit_social_link! unless defer_social_link?
    end

    def defer_social_link?
      false
    end

    # Writes the staged link in one transaction: the provider backfill and
    # the (provider, sub) row land together or not at all, and the staged
    # state is kept until they have, so a failure part-way leaves nothing to
    # reverse. A block, when given, runs inside that transaction after the
    # writes: work the login still has to get through for the link to stand
    # (the web callback's redirect_to, which can raise). It runs even when
    # nothing is staged. SOCIAL_ACCOUNT_LINKED is published only after the
    # transaction has committed.
    #
    # The account row is locked first and must still exist. That serialises
    # this commit with AccountCleanup.destroy_newly_created!, which takes the
    # same lock: an account another, rejected request created and is now
    # removing is never linked to (this login fails and can simply be
    # retried, creating a fresh account), and an account this login has
    # already signed in to is never removed under it (see AccountCleanup).
    def commit_social_link!
      pending = @pending_social_link
      if pending.nil?
        yield if block_given?
        return
      end

      identifier = pending[:identifier]
      begin
        write_social_link!(pending, identifier) { yield if block_given? }
      rescue StandardId::SocialLinkConflictError => e
        # A concurrent login won the link (see the error's reasons).
        # Published here, once the transaction has rolled back, so a
        # subscriber that writes an audit row is not rolled back with the
        # link; and only on this path, so never for a link that commits.
        emit_social_link_blocked(identifier, provider, e.reason)
        raise
      end

      @pending_social_link = nil
      if pending[:backfill_provider]
        identifier.provider = provider.provider_name
        identifier.clear_attribute_changes([:provider]) if identifier.respond_to?(:clear_attribute_changes)
      end
      emit_committed_social_link(identifier, provider) if pending[:emit_linked]
    end

    # The transaction behind commit_social_link!.
    def write_social_link!(pending, identifier)
      ActiveRecord::Base.transaction do
        if StandardId.account_class.lock.where(id: identifier.account_id).pick(:id).nil?
          raise StandardId::InvalidGrantError, SOCIAL_RETRY_MESSAGE
        end

        if pending[:backfill_provider]
          # Conditional, so a provider set concurrently is never overwritten.
          StandardId::Identifier.where(id: identifier.id, provider: nil).update_all(provider: provider.provider_name)
        end
        record_social_identity!(identifier, pending[:subject])
        yield if block_given?
      end
    end

    # SOCIAL_ACCOUNT_LINKED reports a link that has already committed, so it
    # cannot refuse the login: a subscriber that raises here would fail the
    # callback while the link stays. Its error is logged and reported to
    # Rails.error instead of propagating. (Guards belong on the events that
    # run before anything is written.)
    def emit_committed_social_link(identifier, provider)
      emit_social_account_linked(identifier.account, provider, identifier)
    rescue StandardError => e
      Rails.logger&.error("[StandardId] SOCIAL_ACCOUNT_LINKED subscriber raised after the link committed: #{e.class}: #{e.message}")
      Rails.error.report(e, handled: true, source: "standard_id")
    end

    # A social login that recorded a link (and maybe created an account) and
    # was then rejected for ANY reason — policy, hook, invalid scope, audience
    # binding, an unexpected error — must leave nothing behind: drop the link
    # and remove an account this request created. Safe to call when nothing
    # was recorded, and when the account is already gone.
    #
    # When the login matched an EXISTING account, `sessions` / `refresh_tokens`
    # are what this request issued (and has revoked): if a concurrent, refused
    # request kept that account only because this login had signed in to it,
    # the account is removed after all (AccountCleanup.reclaim_for_failed_adopter!).
    def discard_social_attempt!(account, newly_created:, sessions: [], refresh_tokens: [])
      rollback_social_link!
      if newly_created
        StandardId::AccountCleanup.destroy_newly_created!(account)
      else
        StandardId::AccountCleanup.reclaim_for_failed_adopter!(account, sessions:, refresh_tokens:)
      end
    end

    # The login matched an account by email that a concurrent, refused
    # request had created and has since removed (AccountCleanup). The login
    # then fails part-way (its session insert hits the foreign key, or
    # commit_social_link! finds the account gone); the callbacks report that
    # as a retryable invalid_grant rather than a 500. A retry finds no
    # account and creates a fresh one. Check before discard_social_attempt!,
    # which removes an account THIS request created.
    def social_account_removed_concurrently?(account, newly_created:)
      return false if newly_created || account.nil? || account.id.nil?

      !StandardId.account_class.where(id: account.id).exists?
    end

    SOCIAL_RETRY_MESSAGE = "The sign-in could not be completed. Please try again.".freeze

    # Nothing was written for a deferred link, so dropping the staged one is
    # the whole rollback. (A non-deferring caller has already committed it.)
    def rollback_social_link!
      @pending_social_link = nil
    end

    def social_identities_available?
      return true if StandardId::SocialIdentity.available?

      StandardId::SocialAuthentication.warn_social_identities_missing!
      false
    end

    # Logged once per process when the host has not run the migration yet.
    def self.warn_social_identities_missing!
      return if @social_identities_missing_warned

      @social_identities_missing_warned = true
      Rails.logger&.warn(
        "[StandardId] standard_id_social_identities is missing, so social logins are not matched on the " \
        "provider's subject id. Run `bin/rails standard_id:install:migrations && bin/rails db:migrate`."
      )
    end

    def account_has_social_identifier_from?(account, provider)
      account.identifiers.where(type: StandardId::EmailIdentifier.sti_name, provider: provider.provider_name).exists?
    end

    def build_account_from_social(social_info)
      emit_account_creating_from_social(social_info)
      attrs = resolve_account_attributes(social_info)
      account = StandardId.account_class.create!(attrs)
      emit_account_created_from_social(account)
      account
    end

    def resolve_account_attributes(social_info)
      resolver = StandardId.config.social_account_attributes
      attrs = if resolver.respond_to?(:call)
                payload = {
                  social_info: social_info,
                  provider: provider.provider_name
                }

                filtered_payload = StandardId::Utils::CallableParameterFilter.filter(resolver, payload)
                resolver.call(**filtered_payload)
      else
                {
                  email: social_info[:email],
                  name: social_info[:name].presence || social_info[:given_name].presence || social_info[:email]
                }
      end

      unless attrs.is_a?(Hash)
        raise StandardId::InvalidRequestError, "Social account attribute resolver must return a hash"
      end

      attrs.symbolize_keys
    end

    def allow_other_host_redirect?(redirect_uri)
      return false if redirect_uri.blank?

      allowed = Array(StandardId.config.allowed_redirect_url_prefixes)
      return false if allowed.blank?

      allowed.any? do |entry|
        case entry
        when Regexp
          entry.match?(redirect_uri)
        else
          redirect_uri.start_with?(entry.to_s)
        end
      end
    end

    def run_social_callback(provider:, social_info:, provider_tokens:, account:, original_request_params: {})
      emit_social_auth_completed(provider, social_info, provider_tokens, account, original_request_params)
    end

    def emit_social_user_info_fetched(provider, social_info, email)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_USER_INFO_FETCHED,
        provider: provider,
        social_info: social_info,
        email: email
      )
    end

    def emit_social_account_created(account, provider, social_info)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_ACCOUNT_CREATED,
        account: account,
        provider: provider,
        social_info: social_info
      )
    end

    def emit_social_link_blocked(identifier, provider, reason = :link_required)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_LINK_BLOCKED,
        email: identifier.value,
        provider: provider,
        identifier: identifier,
        account: identifier.account,
        reason: reason
      )
    end

    def emit_social_account_linked(account, provider, identifier)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_ACCOUNT_LINKED,
        account: account,
        provider: provider,
        identifier: identifier
      )
    end

    def emit_social_auth_completed(provider, social_info, provider_tokens, account, original_request_params)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_AUTH_COMPLETED,
        account: account,
        provider: provider,
        social_info: social_info,
        tokens: provider_tokens,
        original_request_params: original_request_params
      )
    end

    def emit_account_creating_from_social(social_info)
      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_CREATING,
        account_params: resolve_account_attributes(social_info),
        auth_method: "social:#{provider.provider_name}"
      )
    end

    def emit_account_created_from_social(account)
      StandardId::Events.publish(
        StandardId::Events::ACCOUNT_CREATED,
        account: account,
        auth_method: "social:#{provider.provider_name}",
        source: "social"
      )
    end

    # Emit SOCIAL_AUTH_FAILED for infrastructure-level failures during the
    # social authentication flow (HTTP errors, DNS/SSL/timeouts surfaced as
    # OAuthError by provider implementations).
    #
    # Host apps can subscribe to this event to forward failures to Sentry or
    # similar observability tools without monkey-patching the controller.
    #
    # @param error [StandardId::OAuthError] the captured failure
    # @param account [Object, nil] the account if one was resolved before the failure
    def emit_social_auth_failed(error, account: nil)
      StandardId::Events.publish(
        StandardId::Events::SOCIAL_AUTH_FAILED,
        provider: provider&.provider_name,
        error: error.message,
        error_class: error.class.name,
        account: account
      )
    end
  end
end
