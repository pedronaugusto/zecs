//! Systems: queries with a callback, run by the pipeline.

const c = @import("c/core.zig");
const types = @import("types.zig");
const Error = @import("error.zig").Error;

const Entity = types.Entity;
const QueryDesc = types.QueryDesc;

/// What a system matches, when it runs, and what it does.
pub const SystemDesc = struct {
    name: ?[:0]const u8 = null,

    /// What the system iterates.
    query: QueryDesc = .{},

    /// The pipeline phase to run in — `Builtin.on_update.id()` and friends. Left at 0,
    /// the system is not attached to the pipeline and only runs when `World.run` asks
    /// it to. flecs adds both the phase tag and a `DependsOn` pair for you.
    phase: Entity = 0,

    /// Invoked once per matched table. Build one with `zecs.callback`.
    callback: c.ecs_iter_action_t = null,

    /// Invoked once per system run, taking over iteration entirely. Use for systems
    /// that need to control the loop; otherwise leave null and use `callback`.
    run: c.ecs_run_action_t = null,

    /// Delivered to the callback as `Iter.ctx()`.
    ctx: ?*anyopaque = null,

    /// Run at most this often, in seconds. Zero means every frame.
    interval: c.ecs_ftime_t = 0,

    /// Run once every N frames. Zero and one both mean every frame.
    rate: i32 = 0,

    /// Split matched tables across the worker threads set up by `World.setThreads`.
    ///
    /// The callback must then be safe to run concurrently with itself on different
    /// tables — and, if it allocates, the allocator handed to `setAllocator` has to be
    /// thread-safe.
    multi_threaded: bool = false,

    /// Give the callback the real world rather than a deferred stage, so structural
    /// changes take effect immediately. Cannot be combined with `multi_threaded`.
    immediate: bool = false,

    pub fn toC(self: SystemDesc, entity: Entity) Error!c.ecs_system_desc_t {
        return .{
            .entity = entity,
            .query = try self.query.toC(),
            .phase = self.phase,
            .callback = self.callback,
            .run = self.run,
            .ctx = self.ctx,
            .interval = self.interval,
            .rate = self.rate,
            .multi_threaded = self.multi_threaded,
            .immediate = self.immediate,
        };
    }
};
