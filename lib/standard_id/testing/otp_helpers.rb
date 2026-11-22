module StandardId
  module Testing
    # Raw one-time codes, for specs that need to submit one.
    #
    # A challenge stores only an HMAC of its code (migration 20261122000000),
    # so `StandardId::CodeChallenge.last.code` is nil once the row is read back
    # from the database. The raw code exists only on the record the engine has
    # just created; these helpers capture it from PASSWORDLESS_CODE_GENERATED
    # with StandardId::Passwordless.issued_code, exactly as a delivery
    # subscriber does, so they work whether or not
    # `config.events.publish_records` publishes the record.
    #
    # Usage in rails_helper.rb:
    #
    #   require "standard_id/testing"
    #
    #   RSpec.configure do |config|
    #     config.include StandardId::Testing::OtpHelpers, type: :request
    #   end
    #
    # Example:
    #   code = capture_otp_code { post "/login", params: { email: email } }
    #   patch "/login_verify", params: { code: code }
    #
    module OtpHelpers
      IssuedCode = Data.define(:identifier, :channel, :realm, :code)

      # Every code issued while the block runs, oldest first.
      #
      # @return [Array<IssuedCode>]
      def capture_otp_codes
        codes = []
        subscription = StandardId::Events.subscribe(StandardId::Events::PASSWORDLESS_CODE_GENERATED) do |event|
          code = StandardId::Passwordless.issued_code(event)
          next if code.blank?

          codes << IssuedCode.new(identifier: event[:identifier], channel: event[:channel], realm: event[:realm], code: code)
        end

        yield
        codes
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription) if subscription
      end

      # The last code issued while the block runs, to +identifier+ when given.
      #
      # @return [String]
      # @raise [RuntimeError] when no code was issued
      def capture_otp_code(identifier = nil, &block)
        codes = capture_otp_codes(&block)
        codes = codes.select { |issued| issued.identifier == identifier } if identifier

        codes.last&.code || raise("No one-time code was issued#{" to #{identifier}" if identifier}")
      end
    end
  end
end
