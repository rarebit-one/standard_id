module StandardId
  module WebMechanismGate
    extend ActiveSupport::Concern

    class_methods do
      # Declares which web mechanism this controller requires.
      # If the mechanism is disabled via config, requests return 404.
      #
      #   class SignupController < BaseController
      #     requires_web_mechanism :signup
      #   end
      def requires_web_mechanism(mechanism_name)
        before_action -> { enforce_web_mechanism!(mechanism_name) }
      end
    end

    private

    def enforce_web_mechanism!(mechanism_name)
      unless StandardId.config.web.respond_to?(mechanism_name)
        raise ArgumentError, "Unknown web mechanism: #{mechanism_name.inspect}. " \
              "Valid mechanisms: #{StandardId.config.web.class.instance_methods(false).grep_v(/=/).sort.join(', ')}"
      end

      head :not_found unless StandardId.config.web.public_send(mechanism_name)
    end
  end
end
