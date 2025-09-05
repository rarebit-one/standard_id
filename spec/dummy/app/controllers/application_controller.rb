class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  include StandardId::WebAuthentication

  rescue_from StandardId::NotAuthenticatedError, with: :redirect_to_login

  private

  def redirect_to_login
    redirect_to standard_id_web.login_path(redirect_uri: request.original_fullpath)
  end
end
