module StandardId
  # Reports an error StandardId has handled and is carrying on from (see
  # `config.error_reporter`). Every such report goes through here, so a host
  # that routes them elsewhere catches all of them.
  module ErrorReporting
    SOURCE = "standard_id".freeze

    module_function

    # Without a configured reporter this is exactly the call the engine has
    # always made, `Rails.error.report(error, handled: true, source:
    # "standard_id")`; `context` goes only to a configured reporter.
    #
    # Every caller is a rescue that carries on, so a configured reporter that
    # raises is logged and the error goes to the default report instead.
    #
    # @param error [Exception]
    # @param context [Hash] extra detail for a configured reporter, e.g. the
    #   event whose subscriber raised
    # @return [void]
    def report(error, context = {})
      reporter = StandardId.config.error_reporter
      return report_to_rails(error) unless reporter.respond_to?(:call)

      begin
        reporter.call(error, context.merge(source: SOURCE, handled: true))
      rescue StandardError => e
        Rails.logger&.error("[StandardId] error_reporter raised #{e.class}: #{e.message}; reporting #{error.class} to Rails.error instead")
        report_to_rails(error)
      end
    end

    def report_to_rails(error)
      Rails.error.report(error, handled: true, source: SOURCE)
    end
    private_class_method :report_to_rails
  end
end
