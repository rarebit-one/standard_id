# Minimal stand-in for the two inertia_rails touchpoints StandardId calls.
#
# standard_id has no inertia_rails dependency — hosts opt in, and
# StandardId::InertiaSupport#inertia_available? checks `defined?(::InertiaRails)`
# at runtime. So the real InertiaRails::Controller#inertia_location and the
# ActionDispatch::Request#inertia? extension are absent from this suite, and the
# Inertia redirect branches were previously untestable here (see the note in
# spec/requests/standard_id/api/consent_spec.rb).
#
# These doubles reproduce inertia_rails 3.21.2 exactly:
#
#   lib/inertia_rails/controller.rb:154
#     def inertia_location(url)
#       headers['X-Inertia-Location'] = url
#       head :conflict
#     end
#
#   lib/inertia_rails/extensions/request.rb:5
#     def inertia?
#       key? 'HTTP_X_INERTIA'
#     end
#
# Depending on the real gem in the test group is not currently an option:
# loading it defines ::InertiaRails globally, which unmasks the persistent
# `config.use_inertia = true` in spec/lib/standard_id_spec.rb and makes
# unrelated ERB specs render as Inertia components (12 failures). Fixing that
# config-isolation leak is worth doing, but it is not this bug.
#
# Both modules are inert until a spec opts in: #inertia? is false without the
# X-Inertia header, and #inertia_location is only reachable through
# redirect_with_inertia when use_inertia? is true, which requires ::InertiaRails
# to be defined — which only happens inside an example tagged `:inertia`.
module InertiaDouble
  module Request
    def inertia?
      key? "HTTP_X_INERTIA"
    end
  end

  module Controller
    def inertia_location(url)
      headers["X-Inertia-Location"] = url
      head :conflict
    end
  end
end

ActionDispatch::Request.include(InertiaDouble::Request)
ActiveSupport.on_load(:action_controller_base) { include InertiaDouble::Controller }

RSpec.configure do |config|
  # Turn the Inertia branch on for an example group: `RSpec.describe "...", :inertia`.
  # Send the X-Inertia header on the individual requests that should take it.
  config.before(:each, :inertia) do
    stub_const("InertiaRails", Module.new)
    allow(StandardId.config).to receive(:use_inertia).and_return(true)
  end
end
