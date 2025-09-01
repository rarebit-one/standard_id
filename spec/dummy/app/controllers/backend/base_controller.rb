module Backend
  class BaseController < ApplicationController
    include StandardId::WebAuthentication

    rescue_from StandardId::NotAuthenticatedError, StandardId::ExpiredSessionError, with: :redirect_to_login

    before_action :require_browser_session!

    private

    def redirect_to_login
      redirect_to standard_id_web.login_path, alert: "Please sign in to continue."
    end
  end
end
