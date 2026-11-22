module StandardId
  module Web
    # The step-up page WebAuthentication#require_recent_authentication! sends a
    # stale session to (StandardId::StepUp):
    #
    #   GET   /step_up  → "send me a code", or the code (+ password) form once sent
    #   POST  /step_up  → issues a code to the account's verified e-mail (or phone)
    #   PATCH /step_up  → checks it; on success marks the current session as
    #                     just authenticated and returns to the guarded page
    #
    # Signed-out visitors go to login, as for any authenticated page. Routed
    # only while c.step_up.enabled is true. Inertia apps render
    # "<namespace>/step_up/show" with #step_up_page_props.
    class StepUpController < BaseController
      authenticated_controller

      include StandardId::InertiaRendering

      layout "public"

      rate_limit to: StandardId.config.rate_limits.otp_verify_per_ip,
                 within: 15.minutes,
                 name: "step-up-verify-ip",
                 only: :update,
                 store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

      def show
        render_with_inertia props: step_up_page_props
      end

      def create
        result = StandardId::StepUp.start(account: current_account, request: request)

        if result.success? || result.error_code == :cooldown
          session[:step_up_code_sent] = true
          flash[:notice] = result.success? ? "We sent you a code" : "A code was sent moments ago. Check your inbox"
          redirect_with_inertia engine_path(step_up_path), status: :see_other
        else
          flash.now[:alert] = result.error_message
          render_with_inertia action: :show, props: step_up_page_props, status: :unprocessable_content
        end
      end

      def update
        result = StandardId::StepUp.verify(
          account: current_account,
          code: string_param(:code),
          password: string_param(:password),
          request: request
        )

        unless result.success?
          flash.now[:alert] = result.error_message
          render_with_inertia action: :show, props: step_up_page_props, status: :unprocessable_content
          return
        end

        StandardId::StepUp.mark!(current_session)
        session.delete(:step_up_code_sent)
        destination = session.delete(:return_to_after_step_up)
        destination = safe_post_signin_default unless safe_destination?(destination)
        redirect_after_authentication destination, notice: "Thanks, you're verified"
      end

      private

      # Where the code goes is the account's own verified address, shown so
      # its owner knows where to look.
      def step_up_page_props
        channel, target = StandardId::StepUp.destination_for(current_account)
        {
          flash: { notice: flash[:notice], alert: flash[:alert] }.compact,
          channel: channel,
          target: target,
          code_sent: session[:step_up_code_sent] == true,
          password_required: StandardId::StepUp.password_required?(current_account),
          step_up_path: engine_path(step_up_path)
        }
      end
      helper_method :step_up_page_props
    end
  end
end
