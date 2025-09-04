module StandardId
  module Web
    class BaseController < ApplicationController
      include StandardId::WebAuthentication

      helper StandardId::WebEngine.routes.url_helpers

      layout "standard_id/web/application"
    end
  end
end
