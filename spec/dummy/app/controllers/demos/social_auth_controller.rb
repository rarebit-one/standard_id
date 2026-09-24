module Demos
  class SocialAuthController < ApplicationController
    def index
      @google_enabled = StandardId.social_provider_enabled?(:google)
      @apple_enabled = StandardId.social_provider_enabled?(:apple)
    end
  end
end
