//! Queries: the standing questions a world can be asked.

const std = @import("std");
const c = @import("c.zig");
const types = @import("types.zig");
const iter_mod = @import("iter.zig");
const Error = @import("error.zig").Error;

/// A compiled query.
///
/// Creating one costs matching work; running one does not. Keep queries alive for as
/// long as the thing that asks them, rather than building one per frame.
pub const Query = struct {
    raw: *c.ecs_query_t,
    world: *c.ecs_world_t,

    /// Iteration state. Calls `ecs_query_next` directly rather than through the
    /// iterator's function pointer.
    pub const Iterator = iter_mod.Iterator(&c.ecs_query_next);

    pub fn deinit(self: Query) void {
        c.ecs_query_fini(self.raw);
    }

    /// Starts an iteration.
    ///
    /// ```zig
    /// var it = query.iter();
    /// defer it.deinit();
    /// while (it.next()) |row| {
    ///     for (row.fieldSelf(Position, 0), row.fieldSelf(Velocity, 1)) |*p, v| {
    ///         p.x += v.x * row.deltaTime();
    ///     }
    /// }
    /// ```
    pub fn iter(self: Query) Iterator {
        return .{ .raw = c.ecs_query_iter(self.world, self.raw) };
    }

    /// How much this query currently matches. Counting walks the results, so it is not
    /// free — flecs offers it for diagnostics and sizing, not for the frame loop.
    pub fn count(self: Query) c.ecs_query_count_t {
        return c.ecs_query_count(self.raw);
    }

    /// Whether anything this query matches has changed since it was last iterated.
    /// Needs the query to have been created with change detection.
    pub fn changed(self: Query) bool {
        return c.ecs_query_changed(self.raw);
    }
};

test {
    _ = Error;
    _ = types;
    _ = std;
}
