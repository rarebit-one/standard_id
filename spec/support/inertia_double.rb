# Minimal stand-in for the three inertia_rails touchpoints StandardId calls.
#
# standard_id has no inertia_rails dependency — hosts opt in, and
# StandardId::InertiaSupport#inertia_available? checks `defined?(::InertiaRails)`
# at runtime. So the real InertiaRails::Controller#inertia_location and the
# ActionDispatch::Request#inertia? extension are absent from this suite, and the
# Inertia redirect branches were previously untestable here (see the note in
# spec/requests/standard_id/api/consent_spec.rb).
#
# These doubles reproduce inertia_rails 3.23.0 exactly:
#
#   lib/inertia_rails/controller.rb
#     def inertia_location(url)
#       headers['X-Inertia-Location'] = url
#       head :conflict
#     end
#
#     def redirect_to(options = {}, response_options_and_flash = {})
#       inertia_opts = response_options_and_flash.delete(:inertia) if
#         response_options_and_flash.is_a?(Hash)
#       session[:_inertia_clear_history] = true if inertia_opts&.dig(:clear_history)
#       super
#     end
#
#   lib/inertia_rails/extensions/request.rb
#     def inertia?
#       key? 'HTTP_X_INERTIA'
#     end
#
# All three are inert until a spec opts in: #inertia? is false without the
# X-Inertia header, #inertia_location is only reachable through
# redirect_with_inertia when use_inertia? is true, and the redirect_to override
# only intercepts the inertia: option when called in an :inertia example (where
# ::InertiaRails is defined and use_inertia? is true).
#
# `use_inertia` is written to the real config rather than stubbed, because
# spec/support/config_isolation.rb snapshots and restores the global config
# around every example. That hook is also what makes swapping this double for
# the real gem viable: adding inertia_rails to the test group defines
# ::InertiaRails globally, which is only safe when no example can leave
# `use_inertia = true` behind.
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

    # Mirror inertia_rails' redirect_to override: extract the inertia: option
    # before calling super, and store clear_history in the session so it
    # survives to the next render (the same mechanism the real gem uses).
    def redirect_to(options = {}, response_options_and_flash = {})
      inertia_opts = response_options_and_flash.delete(:inertia) if response_options_and_flash.is_a?(Hash)
      session[:_inertia_clear_history] = true if inertia_opts&.dig(:clear_history)
      super
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
    StandardId.config.use_inertia = true
  end
end
