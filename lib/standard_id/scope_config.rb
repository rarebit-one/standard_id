module StandardId
  class ScopeConfig
    attr_reader :name, :profile_type, :after_sign_in_path, :no_profile_message, :label, :allow_registration

    def initialize(name, config = {})
      @name = name.to_sym
      @profile_type = config[:profile_type]
      @after_sign_in_path = config[:after_sign_in_path]
      @no_profile_message = config[:no_profile_message] || "Access denied. No matching profile found."
      @label = config[:label] || name.to_s.humanize
      @allow_registration = config.fetch(:allow_registration, true)
    end

    def requires_profile?
      profile_type.present?
    end
  end
end
