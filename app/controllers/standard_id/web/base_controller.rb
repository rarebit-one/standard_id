module StandardId
  module Web
    class BaseController < ApplicationController
      include StandardId::WebAuthentication
      include StandardId::SetCurrentRequestDetails

      include StandardId::WebEngine.routes.url_helpers
      helper StandardId::WebEngine.routes.url_helpers

      layout -> { StandardId.config.web_layout.presence || "application" }

      before_action :require_browser_session!
    end
  end
end
