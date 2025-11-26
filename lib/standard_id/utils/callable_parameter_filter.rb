module StandardId
  module Utils
    class CallableParameterFilter
      class << self
        def filter(callable, context)
          return {} unless callable.respond_to?(:call) && context.present?

          payload = context.to_h.symbolize_keys
          accepted_keys = accepted_parameters(callable)
          return payload if accepted_keys.nil?

          payload.slice(*accepted_keys)
        end

        private

        def accepted_parameters(callable)
          parameters = parameter_list(callable)
          return nil if parameters.any? { |type, _| type == :keyrest }

          parameters.map { |_, name| name&.to_sym }.compact
        end

        def parameter_list(callable)
          if callable.respond_to?(:parameters)
            callable.parameters
          elsif callable.respond_to?(:method)
            callable.method(:call).parameters
          else
            []
          end
        end
      end
    end
  end
end
