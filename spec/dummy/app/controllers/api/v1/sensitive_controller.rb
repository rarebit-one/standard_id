module Api
  module V1
    # A host API endpoint behind the step-up guard (StandardId::StepUp), for
    # the request specs.
    class SensitiveController < ApplicationController
      include StandardId::ApiAuthentication

      before_action -> { require_recent_authentication!(within: 5.minutes) }

      def show
        render json: { account: current_account.id }
      end
    end
  end
end
