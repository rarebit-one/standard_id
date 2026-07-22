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
end

RSpec.configure do |config|
  config.around(:each) do |example|
    saved = StandardIdConfigIsolation.snapshot
    example.run
  ensure
    StandardIdConfigIsolation.restore(saved)
  end
end
