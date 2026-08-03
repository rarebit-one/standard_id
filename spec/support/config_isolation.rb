# Suite-wide isolation for StandardId's global configuration.
#
# `StandardId.config` is a process-global singleton (`StandardId::CONFIG`, a
# Concurrent::Delay). Any example that writes to it — directly, via
# `StandardId.configure`, or via `StandardId.register(:scope, resolver)` —
# mutates state every later example reads. Historically specs hand-rolled
# `around` blocks to save/restore the handful of keys they touched, and the
# ones that forgot leaked (e.g. `use_inertia = true`, which silently stayed on
# for the rest of the suite and made a real `inertia_rails` dev dependency
# impossible to add).
#
# This hook removes the need for those hand-rolled blocks: every example is
# wrapped in a snapshot/restore of the whole config tree, so no spec can leak,
# whether or not its author thought about it.
#
# What is snapshotted:
#   * the top-level Config hash (so scopes added mid-example are dropped)
#   * each Scope's raw stored values (bypassing the read-time cast/dup)
#   * each Scope's `resolver` (set by `StandardId.register`)
#
# Scope objects are restored in place (Hash#replace) rather than rebuilt, so
# any reference captured elsewhere keeps pointing at live state.
module StandardIdConfigIsolation
  module_function

  def snapshot
    config = StandardId.config
    top = config.to_h
    scopes = top.each_with_object({}) do |(key, value), acc|
      next unless value.is_a?(StandardId::ConfigSchema::Scope)
      acc[key] = { scope: value, values: value.to_h, resolver: value.resolver }
    end
    { top: top, scopes: scopes }
  end

  def restore(snapshot)
    StandardId.config.replace(snapshot[:top])
    snapshot[:scopes].each_value do |state|
      state[:scope].replace(state[:values])
      state[:scope].resolver = state[:resolver]
    end
  end

  # Replace the memoized Concurrent::Delays behind StandardId.logger and
  # StandardId.cache_store with fresh, unforced ones. They are lazy, so this
  # costs nothing until something reads them, at which point they resolve
  # against whatever the config says *then*.
  def rearm_delays!
    singleton = StandardId.singleton_class
    singleton.send(:remove_const, :LOGGER)
    singleton.const_set(:LOGGER, Concurrent::Delay.new { StandardId.config.logger || Rails.logger })
    singleton.send(:remove_const, :CACHE_STORE)
    singleton.const_set(:CACHE_STORE, Concurrent::Delay.new { StandardId.config.cache_store || Rails.cache })
  end
end

RSpec.configure do |config|
  config.around(:each) do |example|
    saved = StandardIdConfigIsolation.snapshot
    example.run
  ensure
    StandardIdConfigIsolation.restore(saved)
    # `StandardId.logger` / `.cache_store` are Concurrent::Delays derived from
    # the config, and a Delay memoizes for the life of the PROCESS. Restoring
    # the config hash above does not un-force them, so an example that forces
    # one against a doctored config poisons every later example — spec/lib/
    # standard_id_spec.rb sets `config.logger = 'test_logger'` and calls
    # `reset_standard_id_logger!` on the way in but nothing on the way out, so
    # `StandardId.logger` stayed the String "test_logger" for the rest of the
    # run. Any `StandardId.logger&.warn` reached afterwards died with
    # "private method 'warn' called for an instance of String" — seed-dependent,
    # so it surfaced on exactly one Ruby of the CI matrix (rarebit-ops#306).
    # Re-arming both delays here makes that unleakable, per this file's remit.
    StandardIdConfigIsolation.rearm_delays!
  end
end
