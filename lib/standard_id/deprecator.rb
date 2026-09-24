require "active_support/deprecation"

module StandardId
  # The gem's single ActiveSupport::Deprecation instance.
  #
  # The engine registers it in `Rails.application.deprecators[:standard_id]`,
  # so the host's `config.active_support.deprecation` behaviour (:raise in
  # test, :log / :notify in production, ...) and
  # `Rails.application.deprecators.silence` apply to StandardId warnings exactly
  # as they do to Rails' own. An unregistered deprecator only ever printed to
  # stderr, whatever the host configured.
  #
  # @return [ActiveSupport::Deprecation]
  def self.deprecator
    @deprecator ||= ActiveSupport::Deprecation.new("2.0", "StandardId")
  end
end
