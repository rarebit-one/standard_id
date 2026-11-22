# A host page behind the step-up guard (StandardId::StepUp), for the request
# specs.
class SensitiveController < ApplicationController
  before_action :authenticate_account!
  before_action -> { require_recent_authentication!(within: 5.minutes) }

  def show
    render plain: "sensitive for #{current_account.id}"
  end

  def update
    render plain: "updated"
  end
end
