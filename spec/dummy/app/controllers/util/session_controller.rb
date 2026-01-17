module Util
  class SessionController < ApplicationController
    protect_from_forgery with: :null_session

    # POST /util/session
    # Params:
    # - key: session key to set (e.g., "session_token")
    # - value: value to store
    # Alternatively, pass session_token param directly for convenience.
    def set
      key = params[:key].presence || (params.key?(:session_token) ? :session_token : nil)
      value = params[:value].presence || params[:session_token]

      if key.nil?
        render json: { ok: false, error: "missing key or session_token param" }, status: :unprocessable_content
        return
      end

      # Set both session and encrypted cookie for backward compatibility
      # Action Cable will use the encrypted cookie
      session[key.to_sym] = value
      cookies.encrypted[key.to_sym] = value
      render json: { ok: true }
    end
  end
end
