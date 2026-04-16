module StandardId
  module Web
    module ResetPassword
      class StartController < BaseController
        public_controller
        requires_web_mechanism :password_reset

        layout "public"

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
            redirect_to login_path, status: :see_other
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
        def build_reset_url_template
          base = reset_password_confirm_url rescue nil
          base ||= "#{request.base_url}/reset_password/confirm"
          separator = base.include?("?") ? "&" : "?"
          "#{base}#{separator}token={token}"
        end
      end
    end
  end
end
