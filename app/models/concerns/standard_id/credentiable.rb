module StandardId
  module Credentiable
    extend ActiveSupport::Concern

    included do
      # strict_loading: false — `touch: true` makes Rails read this association
      # from inside its own after_create/after_update/after_destroy callbacks
      # (ActiveRecord::Associations::Builder::HasOne.touch_record), which no
      # `includes` at a call site can reach. Without the exemption every save of
      # a PasswordCredential / ClientSecretCredential raises
      # StrictLoadingViolationError in hosts running strict_loading_by_default.
      # It is a one-row has_one read, never an N+1.
      has_one :credential, as: :credentialable, touch: true, strict_loading: false
      accepts_nested_attributes_for :credential

      delegate :account, to: :credential
    end
  end
end
