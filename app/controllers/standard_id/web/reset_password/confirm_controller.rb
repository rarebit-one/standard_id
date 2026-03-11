module StandardId
  module Web
    module ResetPassword
      class ConfirmController < BaseController
        public_controller

        layout "public"

        skip_before_action :require_browser_session!, only: [:show, :update]

        before_action :prepare_password_credential, only: [:show, :update]
        before_action :redirect_if_token_invalid, only: [:show, :update]

        def show
        end

        def update
          form = StandardId::Web::ResetPasswordConfirmForm.new(@password_credential, reset_password_confirm_form_params)

          if form.submit
            flash[:notice] = "Your password has been successfully reset. Please sign in with your new password."
            redirect_to login_path, status: :see_other
          else
            flash.now[:alert] = form.errors.full_messages.to_sentence
            render :show, status: :unprocessable_content
          end
        end

        private

        def prepare_password_credential
          @password_credential = StandardId::PasswordCredential.find_by_token_for(:password_reset, params[:token])
        end

        def reset_password_confirm_form_params
          params.permit(:password, :password_confirmation)
        end

        def redirect_if_token_invalid
          return if @password_credential.present?

          flash[:alert] = "Invalid or expired password reset link"
          redirect_to login_path, status: :see_other
        end
      end
    end
  end
end
