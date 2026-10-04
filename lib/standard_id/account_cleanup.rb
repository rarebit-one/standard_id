module StandardId
  # Removes an account that was created during the current request and then
  # refused sign-in (by a lifecycle hook or the login-method policy), so the
  # refusal does not leave an orphaned account behind.
  #
  # Every association read goes through `.strict_loading(false)`: the account
  # was built in this request, so none of its associations are loaded, and a
  # host running `strict_loading_by_default = true` (most consumers) would
  # otherwise raise StrictLoadingViolationError on `account.sessions` — turning
  # a clean rejection of a new signup into a 500 and leaving the orphaned
  # account behind. Relation-level `strict_loading(false)` also covers the
  # records it loads, so `identifier.credentials` below is safe too.
  module AccountCleanup
    module_function

    def destroy_newly_created!(account)
      return unless account&.persisted?

      ActiveRecord::Base.transaction do
        account.sessions.strict_loading(false).destroy_all
        identifiers = account.identifiers.strict_loading(false).to_a
        identifiers.each { |i| i.credentials.strict_loading(false).destroy_all }
        # Deliberately destroy! (unlike the destroy_all calls above): a failed identifier destroy raises and rolls back the whole cleanup, failing loud instead of leaving a half-cleaned orphan.
        identifiers.each(&:destroy!)
        account.destroy
      end
    end
  end
end
