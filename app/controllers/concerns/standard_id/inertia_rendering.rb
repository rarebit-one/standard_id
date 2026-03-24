module StandardId
  module InertiaRendering
    extend ActiveSupport::Concern

    included do
      include StandardId::InertiaSupport
    end

    private

    # Render with Inertia if enabled, otherwise use standard Rails rendering
    def render_with_inertia(action: nil, props: {}, component: nil, status: :ok, **options)
      if use_inertia?
        component_name = component || inertia_component_name(action)
        render inertia: component_name, props: props, status: status, **options
      else
        render_options = { status: status }
        render_options[:action] = action if action.present?
        render_options.merge!(options.except(:inertia, :props))
        render(**render_options)
      end
    end

    # Generate the Inertia component name based on controller and action
    def inertia_component_name(action = nil)
      namespace = StandardId.config.inertia_component_namespace.presence || "standard_id"
      controller_name = self.class.name.demodulize.delete_suffix("Controller")
      action_str = (action || self.action_name).to_s

      "#{namespace}/#{controller_name}/#{action_str}"
    end

    # Build common props for authentication pages
    def auth_page_props(additional_props = {})
      {
        redirect_uri: @redirect_uri,
        connection: @connection,
        flash: {
          notice: flash[:notice],
          alert: flash[:alert]
        }.compact,
        social_providers: {
          google_enabled: StandardId.config.google_client_id.present?,
          apple_enabled: StandardId.config.apple_client_id.present?
        },
        enabled_mechanisms: web_enabled_mechanisms
      }.deep_merge(additional_props)
    end

    def web_enabled_mechanisms
      web = StandardId.config.web
      {
        password_login: web.password_login,
        signup: web.signup,
        passwordless_login: web.passwordless_login,
        social_login: web.social_login,
        password_reset: web.password_reset,
        email_verification: web.email_verification,
        phone_verification: web.phone_verification,
        sessions_management: web.sessions_management,
        passwordless_registration: web.passwordless_registration
      }
    end
  end
end
