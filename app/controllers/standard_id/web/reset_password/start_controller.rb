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
          form = StandardId::Web::ResetPasswordStartForm.new(email: params[:email])

          if form.submit
            flash[:notice] = "If an account with that email exists, we've sent password reset instructions."
            redirect_to login_path, status: :see_other
          else
            flash.now[:alert] = form.errors[:email].first || "Please enter your email address"
            render :show, status: :unprocessable_content
          end
        end
      end
    end
  end
end
