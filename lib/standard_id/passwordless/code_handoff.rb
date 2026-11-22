module StandardId
  module Passwordless
    # Hands the raw one-time code to delivery without putting it on the event
    # bus.
    #
    # A challenge stores only an HMAC of its code, so the raw code exists only
    # on the in-memory record the strategy has just created. With
    # `config.events.publish_records = true` (the default) that record is
    # PASSWORDLESS_CODE_GENERATED's `code_challenge:`. With it false, the
    # payload carries `code_challenge_id` / `_gid` instead and there would be
    # no way left to reach the code: neither delivery subscribers nor
    # StandardId::Testing::OtpHelpers could see it.
    #
    # The code is NOT added to the payload as a string (or any object wrapping
    # one): audit and event-logging subscribers serialise whole payloads into
    # append-only rows, logs, error-tracker breadcrumbs and job arguments,
    # which is exactly what `publish_records = false` exists to stop. Instead
    # the strategy registers the challenge here, in this thread's (or fiber's)
    # execution state, for exactly as long as the synchronous publish of
    # PASSWORDLESS_CODE_GENERATED runs. A subscriber that wants the code asks
    # for it by name (StandardId::Passwordless.issued_code(event)); one that
    # serialises the payload never sees it. Once the publish returns the entry
    # is gone, and another thread, a background job or a later step of the
    # request gets nil.
    #
    # Entries are a stack, so an OTP issued from inside a subscriber (nested
    # publish) is answered for its own event and then popped.
    module CodeHandoff
      STATE_KEY = :standard_id_passwordless_code_handoff

      module_function

      # Registers +challenge+ as the one being published while the block runs.
      def with(challenge)
        stack = (ActiveSupport::IsolatedExecutionState[STATE_KEY] ||= [])
        stack.push(challenge)
        begin
          yield
        ensure
          stack.pop
          ActiveSupport::IsolatedExecutionState.delete(STATE_KEY) if stack.empty?
        end
      end

      # The in-memory challenge a PASSWORDLESS_CODE_GENERATED event was
      # published for, or nil.
      #
      # The published record when there is one; otherwise the challenge being
      # published right now on this thread, provided +event+ is a
      # PASSWORDLESS_CODE_GENERATED event and its `code_challenge_id` (when the
      # payload has one) is that challenge's. Anything else gets nil: another
      # event, an event replayed later or elsewhere, or one for a different
      # challenge.
      #
      # @param event [StandardId::Events::Event, Hash] the event or its payload
      # @return [StandardId::CodeChallenge, nil]
      def challenge_for(event)
        record = event[:code_challenge]
        return record unless record.nil?
        return nil unless event[:event_type].to_s == StandardId::Events::PASSWORDLESS_CODE_GENERATED

        current = ActiveSupport::IsolatedExecutionState[STATE_KEY]&.last
        return nil unless current

        id = event[:code_challenge_id]
        return nil if id.present? && id.to_s != current.id.to_s

        current
      end
    end
  end
end
