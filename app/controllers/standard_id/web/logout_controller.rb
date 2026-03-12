module StandardId
  module Web
    class LogoutController < BaseController
      # Classified as authenticated (not public) because logout requires
      # host-app authentication. The controller handles unauthenticated
      # users gracefully via redirect_if_not_authenticated rather than
      # raising, and skips require_browser_session! to allow session
      # revocation even with an expired browser session.
      authenticated_controller

      skip_before_action :require_browser_session!, only: [:create]

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
