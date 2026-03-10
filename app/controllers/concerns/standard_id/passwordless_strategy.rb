module StandardId
  module PasswordlessStrategy
    extend ActiveSupport::Concern

    STRATEGY_MAP = {
      "email" => StandardId::Passwordless::EmailStrategy,
      "sms"   => StandardId::Passwordless::SmsStrategy
    }.freeze

    private

    def strategy_for(connection)
      klass = STRATEGY_MAP[connection]
      raise StandardId::InvalidRequestError, "Unsupported connection type: #{connection}" unless klass
      klass.new(request)
    end
  end
end
