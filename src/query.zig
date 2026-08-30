//! Queries: the standing questions a world can be asked.

const std = @import("std");
const c = @import("c/query.zig");
const types = @import("types.zig");
const iter_mod = @import("iter.zig");
const Error = @import("error.zig").Error;

/// A compiled query.
///
/// Creating one costs compiling the terms into a plan. Whether it also costs MATCHING
/// depends on the caching policy, and the difference is the whole performance story:
///
/// * a **cached** query keeps the list of matching tables and maintains it as tables
///   appear and disappear, so iterating is a walk over that list;
/// * an **uncached** query walks the world's component records and re-derives the
///   matching tables every time it is iterated.
///
/// `QueryDesc.cache_kind` defaults to `.default`, which is flecs's own default and
/// means *let flecs decide*: it caches when the query belongs to an entity — a system,
/// an observer, a named query — or when it uses a feature that cannot work without a
/// cache (`order_by`, `group_by`, a `Cascade` term, change detection), and does not
/// otherwise [read-from-source: `flecs_query_set_caching_policy`,
/// `libs/flecs/flecs.c:35944`]. `World.query` passes the descriptor through unchanged,
/// so a query built there with no `entity` and none of those features is UNCACHED, and
/// re-matches on every `iter()`.
///
/// That is the right default for a query asked once. For a standing query — one kept
/// for the lifetime of the thing that asks it, which is what this type is for — pass
/// `.cache_kind = .auto` and pay the matching once.
///
/// `cacheKind()` reports what flecs settled on, so the choice is observable rather than
/// inferred from this comment. Note that `.auto` frequently resolves to `.all`: flecs
/// simplifies a fully cacheable query's policy, which is why the tests below assert
/// "not `.none`" for it rather than an exact value.
///
/// A build with flecs's `FLECS_DEFAULT_TO_UNCACHED_QUERIES` — `-Ddefault_to_uncached_queries`,
/// off by default — turns `.default` into `.none` even for entity-owned queries, unless
/// the query needs a cache to work at all.
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

    /// The caching policy flecs SETTLED ON, which is never `.default`: flecs resolves
    /// that at creation into one of the other three and stores the answer on the query
    /// [read-from-source: `libs/flecs/flecs.c:35991`-`36050`]. Reading it back is what
    /// makes the paragraph above this type a checkable claim rather than a description.
    pub fn cacheKind(self: Query) types.CacheKind {
        return @enumFromInt(self.raw.cache_kind);
    }
};

test "the caching policy flecs settles on is the one this type documents" {
    // The claim on `Query` used to be that creating one costs matching and running one
    // does not. That is only true of a cached query, and `World.query` produces an
    // uncached one by default — so the sentence was false for exactly the queries this
    // package hands out. Asserting the resolved policy is what stops the doc and the
    // behaviour from drifting apart again.
    const zecs = @import("zecs.zig");
    if (!zecs.options.addon_system) return error.SkipZigTest;

    const world = try zecs.World.init();
    defer world.deinit();

    const Position = struct { x: f32 = 0 };
    const position = try world.component(Position, .{});

    // Flecs's default, with no owning entity and no cache-requiring feature: uncached.
    const plain = try world.query(.{ .terms = &.{.{ .id = position.asId() }} });
    defer plain.deinit();
    try std.testing.expectEqual(types.CacheKind.none, plain.cacheKind());

    // Asked for: cached. `.auto` on a fully cacheable query resolves to `.all`, which
    // is flecs simplifying its own plan — so the assertion is that it is cached, not
    // which of the two cached kinds it picked.
    const cached = try world.query(.{
        .terms = &.{.{ .id = position.asId() }},
        .cache_kind = .auto,
    });
    defer cached.deinit();
    try std.testing.expect(cached.cacheKind() != .none);

    // And the resolution never leaves `.default` behind for a caller to trip over.
    try std.testing.expect(plain.cacheKind() != .default);
    try std.testing.expect(cached.cacheKind() != .default);
}

test {
    _ = Error;
    _ = types;
    _ = std;
}
