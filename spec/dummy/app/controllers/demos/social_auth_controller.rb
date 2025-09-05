module Demos
  class SocialAuthController < ApplicationController
    def index
      @google_enabled = StandardId.config.respond_to?(:google_client_id) && StandardId.config.google_client_id.present?
      @apple_enabled = StandardId.config.respond_to?(:apple_client_id) && StandardId.config.apple_client_id.present?
    end
  end
end
