module StandardId
  module CurrentAttributes
    extend ActiveSupport::Concern

    included do
      attribute :session, :account, :request_id, :ip_address, :user_agent
    end
  end
end
