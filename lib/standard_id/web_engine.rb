require "standard_id/errors"

module StandardId
  class WebEngine < ::Rails::Engine
    isolate_namespace StandardId

    paths["config/routes.rb"] = "config/routes/web.rb"
  end
end
