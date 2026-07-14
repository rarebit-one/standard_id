module StandardId
  module Web
    module ResetPassword
      class StartController < BaseController
        public_controller
        requires_web_mechanism :password_reset

        layout "public"

        # Rate limit reset-request generation by IP (10 per hour). The endpoint
        # emails a reset token, so without a limit it's an email-flooding vector.
        rate_limit to: StandardId.config.rate_limits.password_reset_start_per_ip,
                   within: 1.hour,
                   name: "reset-password-ip",
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        # Rate limit reset requests by email target (3 per 15 minutes) to blunt
        # account-enumeration probing of individual addresses. A blank email
        # would collapse into one shared "reset-password:" bucket (`.compact`
        # does not drop a non-nil empty string), throttling everyone; fall the
        # key back to the remote IP when blank so it stays bounded per-IP without
        # poisoning real targets.
        rate_limit to: StandardId.config.rate_limits.password_reset_start_per_target,
                   within: 15.minutes,
                   by: -> {
                     email = params[:email].to_s.strip.downcase
                     "reset-password:#{email.presence || request.remote_ip}"
                   },
                   name: "reset-password-target",
                   only: :create,
                   store: StandardId::RateLimitHandling::RATE_LIMIT_STORE

        skip_before_action :require_browser_session!, only: [:show, :create]

        def show
          # Display the password reset request form
        end

        def create
          form = StandardId::Web::ResetPasswordStartForm.new(
            email: params[:email],
            reset_url_template: build_reset_url_template
          )

          if form.submit
            flash[:notice] = "If an account with that email exists, we've sent password reset instructions."
            redirect_to engine_path(login_path), status: :see_other
          else
            flash.now[:alert] = form.errors[:email].first || "Please enter your email address"
            render :show, status: :unprocessable_content
          end
        end

        private

        # Build a password-reset URL template containing a literal "{token}"
        # placeholder. The async delivery job substitutes the placeholder with
        # the generated token once the account lookup completes. We build this
        # here (rather than in the job) so the URL reflects the request's
        # scheme/host/port — the job has no access to the HTTP request.
        #
        # The route helper may be absent if the host app mounts the engine
        # without the `:password_reset` mechanism, or raise UrlGenerationError
        # if required params are missing; fall back to a request-derived URL
        # in those cases. Any other exception should surface normally.
        def build_reset_url_template
          base = begin
            reset_password_confirm_url
          rescue NameError, NoMethodError, ActionController::UrlGenerationError
            nil
          end
          base ||= "#{request.base_url}/reset_password/confirm"
          separator = base.include?("?") ? "&" : "?"
          "#{base}#{separator}token={token}"
        end
      end
    end
  end
end
