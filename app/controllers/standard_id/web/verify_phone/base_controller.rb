module StandardId
  module Web
    module VerifyPhone
      class BaseController < StandardId::Web::BaseController
        public_controller
        requires_web_mechanism :phone_verification

        skip_before_action :require_browser_session!
      end
    end
  end
end
