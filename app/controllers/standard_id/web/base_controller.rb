module StandardId
  module Web
    class BaseController < ApplicationController
      include StandardId::ControllerPolicy
      include StandardId::WebAuthentication
      include StandardId::SetCurrentRequestDetails

      include StandardId::WebEngine.routes.url_helpers
      helper StandardId::WebEngine.routes.url_helpers

      layout -> { StandardId.config.web_layout.presence || "application" }

      before_action -> { Current.scope = :web if defined?(::Current) }
      before_action :require_browser_session!
    end
  end
end
