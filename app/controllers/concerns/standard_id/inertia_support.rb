# frozen_string_literal: true

module StandardId
  module InertiaSupport
    extend ActiveSupport::Concern

    included do
      helper_method :use_inertia? if respond_to?(:helper_method)
    end

    private

    # Check if Inertia rendering should be used
    def use_inertia?
      StandardId.config.use_inertia && inertia_available?
    end

    # Check if inertia_rails gem is available in the host application
    def inertia_available?
      defined?(::InertiaRails)
    end

    # Redirect to an external URL or non-Inertia endpoint
    # Uses inertia_location for Inertia requests, otherwise standard redirect_to
    def redirect_with_inertia(url, **options)
      if use_inertia? && request.inertia?
        inertia_location url
      else
        redirect_to url, **options
      end
    end
  end
end
