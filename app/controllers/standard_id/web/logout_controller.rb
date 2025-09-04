module StandardId
  module Web
    class LogoutController < BaseController
      before_action :redirect_if_not_authenticated

      def create
        revoke_current_session!
        redirect_to params[:redirect_uri] || root_path, notice: "Successfully signed out"
      end

      private

      def redirect_if_not_authenticated
        redirect_to params[:redirect_uri] || root_path unless authenticated?
      end
    end
  end
end
