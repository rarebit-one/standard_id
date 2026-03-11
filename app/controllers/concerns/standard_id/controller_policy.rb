require "monitor"
require "set"

module StandardId
  module ControllerPolicy
    extend ActiveSupport::Concern

    included do
      class_attribute :_standard_id_auth_policy, instance_writer: false
    end

    class_methods do
      # Declares this controller as public (no host-app auth required).
      #
      # NOTE: The policy attribute (_standard_id_auth_policy) propagates to
      # subclasses via Ruby's class_attribute inheritance, but registry
      # membership does NOT. A subclass that omits the declaration will
      # inherit the attribute value but will not appear in the registry and
      # will not receive AuthorizationBypass skip_before_action calls.
      # Subclasses that need bypass must call public_controller or
      # authenticated_controller explicitly.
      def public_controller
        self._standard_id_auth_policy = :public
        ControllerPolicy.register(self, :public)
      end

      # Declares this controller as authenticated (requires host-app
      # authentication but not authorization). See public_controller for
      # the inheritance caveat.
      def authenticated_controller
        self._standard_id_auth_policy = :authenticated
        ControllerPolicy.register(self, :authenticated)
      end
    end

    # Monitor instead of Mutex: registry is called from within synchronized
    # blocks (e.g. register, public_controllers), so we need reentrant locking.
    LOCK = Monitor.new
    private_constant :LOCK

    class << self
      def public_controllers
        LOCK.synchronize { registry[:public].dup }
      end

      def authenticated_controllers
        LOCK.synchronize { registry[:authenticated].dup }
      end

      def all_controllers
        LOCK.synchronize { registry[:public] + registry[:authenticated] }
      end

      # Registers a controller under the given policy. Raises if the
      # controller is already registered under the opposite policy.
      # Re-registering under the same policy is a safe no-op (Set semantics).
      def register(controller, policy)
        LOCK.synchronize do
          other = policy == :public ? :authenticated : :public
          if registry[other].include?(controller)
            raise ArgumentError, "#{controller} is already registered as #{other}"
          end

          registry[policy] << controller
        end

        # If AuthorizationBypass has already been applied, apply skips to this
        # newly registered controller immediately. This handles dev-mode lazy
        # loading where controllers register after the initial apply_skips! call.
        AuthorizationBypass.apply_to_controller(controller, policy) if AuthorizationBypass.applied?
      end

      def registry
        LOCK.synchronize { @registry ||= { public: Set.new, authenticated: Set.new } }
      end

      # Returns a point-in-time copy of the registry, safe to iterate
      # without holding the lock.
      def registry_snapshot
        LOCK.synchronize do
          (@registry ||= { public: Set.new, authenticated: Set.new })
            .transform_values(&:dup)
        end
      end

      # @api private — intended for test isolation only.
      def reset_registry!
        LOCK.synchronize do
          @registry = { public: Set.new, authenticated: Set.new }
        end
      end
    end
  end
end
