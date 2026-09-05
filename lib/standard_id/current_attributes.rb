module StandardId
  module CurrentAttributes
    extend ActiveSupport::Concern

    included do
      attribute :session, :account, :request_id, :ip_address, :user_agent, :scope
      # Set once Web::SessionManager has answered "which session / account is
      # this request?" — including when the answer is nil — so the lookup is
      # never repeated within a request. Reset with the rest of Current.
      attribute :session_resolved, :account_resolved
    end
  end
end
