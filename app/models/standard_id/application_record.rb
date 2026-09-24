module StandardId
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # Load +associations+ onto already-instantiated +records+ without tripping
    # strict loading.
    #
    # Gem models run under hosts that set `strict_loading_by_default = true`.
    # A lazy `record.account` then raises ActiveRecord::StrictLoadingViolationError
    # even for a single-row belongs_to read. Where the gem did not load the
    # record itself (model callbacks, records handed in by host code) it cannot
    # add `includes` at the query, so it preloads here instead — the supported
    # Rails API, which also skips associations that are already loaded.
    #
    # @return [Array<ActiveRecord::Base>] the records
    def self.preload_associations(records, *associations)
      records = Array(records).compact
      return records if records.empty?

      ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
      records
    end

    private

    def preload_associations(*associations)
      StandardId::ApplicationRecord.preload_associations(self, *associations)
      self
    end
  end
end
