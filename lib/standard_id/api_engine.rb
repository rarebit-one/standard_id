require "standard_id/errors"

module StandardId
  class ApiEngine < ::Rails::Engine
    isolate_namespace StandardId

    paths["config/routes.rb"] = "config/routes/api.rb"
  end
end
