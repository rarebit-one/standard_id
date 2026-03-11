module StandardId
  module AuthorizationBypass
    FRAMEWORK_CALLBACKS = {
      action_policy: :verify_authorized,
      pundit: :verify_authorized,
      cancancan: :check_authorization
    }.freeze

    MUTEX = Mutex.new
    private_constant :MUTEX

    class << self
      # Skips the host app's authorization callback on all engine controllers,
      # and also skips authenticate_account! on public controllers (login,
      # signup, callbacks, etc.) since those must be accessible without a session.
      #
      # In production (eager_load=true), controllers are already loaded when
      # this runs so the registry is populated. In development (eager_load=false),
      # controllers are loaded lazily on first request; newly registered
      # controllers receive skips immediately via apply_to_controller (called
      # from ControllerPolicy.register). The to_prepare block handles class
      # reloading — after Zeitwerk unloads/reloads classes, the freshly loaded
      # controllers re-register and receive skips again.
      def apply(framework: nil, callback: nil)
        if framework && callback
          raise ArgumentError, "Provide framework: or callback:, not both"
        end

        register_prepare = false

        MUTEX.synchronize do
          # Guard against duplicate to_prepare registrations if called more than
          # once (e.g. in tests or misconfigured initializers). skip_before_action
          # is idempotent so duplicates are harmless, but this keeps things tidy.
          return if @callback_name

          @callback_name = resolve_callback(framework, callback)
          # @prepared is intentionally NOT cleared by reset!. This ensures
          # at most one to_prepare block is registered per process lifetime.
          # Trade-off: after reset! + apply (e.g. in tests switching
          # frameworks), the to_prepare code path is not re-registered, so
          # it can only be verified by the first test that calls apply.
          register_prepare = !@prepared
          @prepared = true
        end

        apply_skips!

        # Re-apply after class reloading in development. In dev (eager_load=false),
        # reset_registry! + apply_skips! is effectively a no-op because the
        # registry is empty at this point — lazy-loaded controllers haven't
        # registered yet. The real work for lazy-loaded controllers is done by
        # apply_to_controller (called from ControllerPolicy.register). This
        # block is still needed because after a Zeitwerk reload, controllers
        # re-register and apply_to_controller fires again for each one, but the
        # reset_registry! here clears stale references to the old class objects
        # to prevent memory leaks in long dev sessions.
        return unless register_prepare

        Rails.application.config.to_prepare do
          StandardId::ControllerPolicy.reset_registry!
          StandardId::AuthorizationBypass.apply_skips!
        end
      end

      # Whether apply has been called. Used by ControllerPolicy.register to
      # decide if newly loaded controllers need immediate skip_before_action.
      def applied?
        MUTEX.synchronize { !@callback_name.nil? }
      end

      # Apply skips to a single controller. Called by ControllerPolicy.register
      # when a controller is lazily loaded after apply has already been called.
      def apply_to_controller(controller, policy)
        callback = MUTEX.synchronize { @callback_name }
        return unless callback

        controller.skip_before_action callback, raise: false
        if policy == :public
          # authenticate_account! is defined in WebAuthentication, not on API
          # controllers. raise: false ensures this is a safe no-op for API
          # controllers that don't have the callback.
          controller.skip_before_action :authenticate_account!, raise: false
        end
      end

      # @api private — called internally by apply and the to_prepare block.
      # Must remain public because it is invoked from a to_prepare lambda
      # registered in apply, which executes outside this module's scope.
      def apply_skips!
        StandardId::ControllerPolicy.registry_snapshot.each do |policy, controllers|
          controllers.each { |controller| apply_to_controller(controller, policy) }
        end
      end

      # @api private — intended for test isolation only.
      # NOTE: This clears @callback_name (so applied? returns false and apply
      # can be called again with a different framework) but intentionally does
      # NOT clear @prepared, so no additional to_prepare block is registered.
      def reset!
        MUTEX.synchronize { @callback_name = nil }
      end

      private

      def resolve_callback(framework, callback)
        if callback
          callback.to_sym
        elsif framework
          FRAMEWORK_CALLBACKS.fetch(framework.to_sym) do
            raise ArgumentError, "Unknown framework: #{framework}. " \
              "Supported: #{FRAMEWORK_CALLBACKS.keys.join(', ')}. " \
              "Or pass callback: :your_callback_name instead."
          end
        else
          raise ArgumentError, "Provide either framework: or callback:"
        end
      end
    end
  end
end
