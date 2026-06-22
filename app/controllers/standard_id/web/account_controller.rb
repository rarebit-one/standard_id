module StandardId
  module Web
    class AccountController < BaseController
      authenticated_controller

      def show
        @account = current_account
        @sessions = current_account.sessions.active.order(created_at: :desc)
      end

      def edit
        @account = current_account
      end

      def update
        @account = current_account

        if @account.update(account_params)
          redirect_to engine_path(account_path), notice: "Account updated successfully"
        else
          flash.now[:alert] = @account.errors.full_messages.join(", ")
          render :edit, status: :unprocessable_content
        end
      end

      private

      def account_params
        # Add account fields as they're defined in the Account model
        params.require(:account).permit()
      end
    end
  end
end
