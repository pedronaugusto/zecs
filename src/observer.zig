//! Observers: callbacks that fire when something happens to matching entities.

const c = @import("c/core.zig");
const types = @import("types.zig");
const Error = @import("error.zig").Error;

const Entity = types.Entity;
const QueryDesc = types.QueryDesc;

/// What an observer watches for.
pub const ObserverDesc = struct {
    name: ?[:0]const u8 = null,

    /// What the observer matches. An observer's query is evaluated against the entity
    /// the event happened to, not against the whole world.
    query: QueryDesc = .{},

    /// The events to watch: `&.{ Builtin.on_set.id() }` and so on. At least one is
    /// required; flecs refuses an observer with none.
    events: []const Entity = &.{},

    /// Fire immediately for entities that already match, as though the event had just
    /// happened to each of them. Useful for observers registered after the fact.
    yield_existing: bool = false,

    /// Invoked when the event fires. Build one with `zecs.callback`.
    callback: c.ecs_iter_action_t = null,

    /// Delivered to the callback as `Iter.ctx()`.
    ctx: ?*anyopaque = null,

    pub fn toC(self: ObserverDesc, entity: Entity) Error!c.ecs_observer_desc_t {
        if (self.events.len > types.event_count_max) return Error.TooManyEvents;

        var desc = c.ecs_observer_desc_t{
            .entity = entity,
            .query = try self.query.toC(),
            .yield_existing = self.yield_existing,
            .callback = self.callback,
            .ctx = self.ctx,
        };
        for (self.events, 0..) |event, i| desc.events[i] = event;
        return desc;
    }
};
