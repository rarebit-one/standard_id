module StandardId
  # Records a user's prior consent to an OAuth client, so repeat authorizations
  # for the same (account, client) skip the consent screen. One row per
  # (account, client); re-approval updates the stored scope.
  class ClientGrant < ApplicationRecord
    self.table_name = "standard_id_client_grants"

    belongs_to :account, class_name: StandardId.config.account_class_name

    validates :client_id, presence: true
    validates :account_id, uniqueness: { scope: :client_id }

    # Whether `account` has already consented to `client_id` covering every
    # scope token in `requested_scope`. A grant with a nil/blank stored scope
    # is treated as covering nothing new only when the request also asks for
    # nothing (blank request) — otherwise the requested tokens must all be a
    # subset of the previously granted set.
    def self.granted?(account:, client_id:, requested_scope: nil)
      return false if account.nil? || client_id.blank?

      grant = find_by(account_id: account.id, client_id: client_id)
      return false unless grant

      requested = scope_tokens(requested_scope)
      return true if requested.empty?

      granted = scope_tokens(grant.scope)
      (requested - granted).empty?
    end

    # Record (or update) a grant for the given account + client + scope.
    def self.record!(account:, client_id:, scope: nil)
      grant = find_or_initialize_by(account_id: account.id, client_id: client_id)
      grant.scope = scope
      grant.save!
      grant
    end

    def self.scope_tokens(value)
      value.to_s.split(/\s+/).map(&:strip).reject(&:blank?).uniq
    end
    private_class_method :scope_tokens
  end
end
