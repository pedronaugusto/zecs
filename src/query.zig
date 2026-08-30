//! Queries: the standing questions a world can be asked.

const std = @import("std");
const c = @import("c/query.zig");
const types = @import("types.zig");
const iter_mod = @import("iter.zig");
const terms_mod = @import("terms.zig");
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
/// `QueryOptions.cache_kind` defaults to `.default`, which is flecs's own default and
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
/// `.options = .{ .cache_kind = .auto }` and pay the matching once.
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

    //=========================================================================
    // Groups
    //
    // Only for a query built with `QueryOptions.group_by`. flecs sorts the cache so a
    // group's tables are contiguous, which is what makes iterating one group a range
    // rather than a filter.
    //=========================================================================

    /// Starts an iteration restricted to one group.
    ///
    /// flecs requires the group to be set before the first `next` and forbids structural
    /// changes in between [read-from-source: `ecs_iter_set_group`], so the call is here
    /// rather than on the iterator: there is no point at which a caller holding one of
    /// these could legally make it.
    pub fn iterGroup(self: Query, group_id: u64) Iterator {
        var it = Iterator{ .raw = c.ecs_query_iter(self.world, self.raw) };
        c.ecs_iter_set_group(&it.raw, group_id);
        return it;
    }

    /// What flecs knows about one group: how many tables it holds, and the context its
    /// `on_create` callback returned. Null when the group has no tables.
    pub fn groupInfo(self: Query, group_id: u64) ?*const c.ecs_query_group_info_t {
        return c.ecs_query_get_group_info(self.raw, group_id);
    }
};

//=============================================================================
// Ordering and grouping
//
// flecs takes C function pointers for both. These turn ordinary Zig functions into them,
// for the same reason `zecs.callback` does: the thunk is generated at compile time and
// compiles to the C-ABI function that would otherwise be written by hand, while the
// comparison itself stays ordinary Zig — and returns `std.math.Order` rather than a
// three-valued `c_int` whose sign convention has to be remembered.
//=============================================================================

/// A comparator over a component's values, for `OrderBy.compare`.
///
/// ```zig
/// .order_by = .{
///     .component = depth.asId(),
///     .compare = zecs.orderBy(Depth, struct {
///         fn cmp(_: zecs.Entity, a: *const Depth, _: zecs.Entity, b: *const Depth) std.math.Order {
///             return std.math.order(a.level, b.level);
///         }
///     }.cmp),
/// }
/// ```
pub fn orderBy(
    comptime T: type,
    comptime compare: fn (e1: types.Entity, a: *const T, e2: types.Entity, b: *const T) std.math.Order,
) c.ecs_order_by_action_t {
    return &struct {
        fn thunk(
            e1: types.Entity,
            p1: ?*const anyopaque,
            e2: types.Entity,
            p2: ?*const anyopaque,
        ) callconv(.c) c_int {
            const a: *const T = @ptrCast(@alignCast(p1.?));
            const b: *const T = @ptrCast(@alignCast(p2.?));
            return orderToC(compare(e1, a, e2, b));
        }
    }.thunk;
}

/// A comparator over entities alone, for an `OrderBy` with no `component`. flecs passes
/// null value pointers in that case, so a comparator built by `orderBy` would fault.
pub fn orderByEntity(
    comptime compare: fn (e1: types.Entity, e2: types.Entity) std.math.Order,
) c.ecs_order_by_action_t {
    return &struct {
        fn thunk(
            e1: types.Entity,
            p1: ?*const anyopaque,
            e2: types.Entity,
            p2: ?*const anyopaque,
        ) callconv(.c) c_int {
            _ = p1;
            _ = p2;
            return orderToC(compare(e1, e2));
        }
    }.thunk;
}

/// flecs sorts ascending on a negative-zero-positive result, the way `qsort` does.
inline fn orderToC(order: std.math.Order) c_int {
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// Sorts by entity id — creation order, since flecs hands out ids in ascending order
/// within a world. The comparator flecs's own pipeline uses to break ties between two
/// systems in the same phase.
pub const orderByEntityId = orderByEntity(struct {
    fn cmp(e1: types.Entity, e2: types.Entity) std.math.Order {
        return std.math.order(e1, e2);
    }
}.cmp);

/// Derives a group id from a table, for `GroupBy.callback`. Leave the callback null to
/// take flecs's own, which groups by the target of the relationship in `GroupBy.id`.
pub fn groupBy(
    comptime f: fn (world: *c.ecs_world_t, table: *c.ecs_table_t, id: types.Id, ctx: ?*anyopaque) u64,
) c.ecs_group_by_action_t {
    return &struct {
        fn thunk(
            world: ?*c.ecs_world_t,
            table: ?*c.ecs_table_t,
            id: types.Id,
            ctx: ?*anyopaque,
        ) callconv(.c) u64 {
            return f(world.?, table.?, id, ctx);
        }
    }.thunk;
}

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
        .options = .{ .cache_kind = .auto },
    });
    defer cached.deinit();
    try std.testing.expect(cached.cacheKind() != .none);

    // And the resolution never leaves `.default` behind for a caller to trip over.
    try std.testing.expect(plain.cacheKind() != .default);
    try std.testing.expect(cached.cacheKind() != .default);
}

/// A query whose terms were derived from a tuple of component handles, and whose results
/// come back as typed slices in the same order.
///
/// This is `Query` plus the derivation in `terms.zig`: the term list and the field reads
/// are one list rather than two, and the element type of every slice is the one the
/// handle carried. Everything `Query` can do, this can do — `query` is the untyped
/// object underneath, and is public for the operations that do not need the types.
///
/// ```zig
/// const q = try world.queryOf(.{ position, zecs.in(velocity) }, .{});
/// defer q.deinit();
///
/// // Per table: contiguous slices, which is the shape an archetype ECS exists for.
/// var it = q.iter();
/// defer it.deinit();
/// while (it.next()) |row| {
///     const p, const v = row.fields;
///     for (p, v) |*pos, vel| pos.x += vel.x * row.deltaTime();
/// }
///
/// // Or per entity, when the body genuinely needs one at a time.
/// q.each({}, struct {
///     fn body(_: void, e: zecs.Entity, p: *Position, v: *const Velocity) void {
///         _ = e;
///         p.x += v.x;
///     }
/// }.body);
/// ```
pub fn QueryOf(comptime Tuple: type) type {
    return struct {
        const Self = @This();

        /// The derivation: term list, row type, field indices.
        pub const spec = terms_mod.Spec(Tuple);

        /// One matched table, typed.
        pub const Row = terms_mod.TypedRow(spec);

        /// The untyped query underneath. Holding it rather than re-wrapping every
        /// operation is what keeps one home for `count`, `changed`, `cacheKind` and the
        /// raw pointer.
        query: Query,

        pub fn deinit(self: Self) void {
            self.query.deinit();
        }

        /// Iteration state, yielding typed rows.
        pub const Iterator = struct {
            inner: Query.Iterator,

            /// The next table, or null when there are none left.
            pub fn next(self: *Iterator) ?Row {
                const it = self.inner.next() orelse return null;
                return .{ .it = it, .fields = spec.row(it) };
            }

            /// Releases the iterator if the loop did not run to completion. Correct to
            /// `defer` either way, for the same reason `Query.Iterator.deinit` is.
            pub fn deinit(self: *Iterator) void {
                self.inner.deinit();
            }
        };

        pub fn iter(self: Self) Iterator {
            return .{ .inner = self.query.iter() };
        }

        /// Iteration restricted to one group. See `Query.iterGroup`.
        pub fn iterGroup(self: Self, group_id: u64) Iterator {
            return .{ .inner = self.query.iterGroup(group_id) };
        }

        /// Calls `body(ctx, entity, ptr...)` once per matched entity, over every table.
        ///
        /// Runs the iteration to completion, so there is nothing to release. `ctx` is
        /// whatever the body needs and may be `{}`.
        pub fn each(self: Self, ctx: anytype, comptime body: anytype) void {
            var it = self.iter();
            defer it.deinit();
            while (it.next()) |row| row.each(ctx, body);
        }
    };
}

test "a typed query reads the components its spec named" {
    const zecs = @import("zecs.zig");

    const world = try zecs.World.init();
    defer world.deinit();

    const Position = struct { x: f32 = 0 };
    const Velocity = struct { x: f32 = 0 };
    const Frozen = struct {};

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});
    const frozen = try world.component(Frozen, .{});

    const moving = world.newEntity();
    world.set(moving, position, .{ .x = 0 });
    world.set(moving, velocity, .{ .x = 2 });

    const stuck = world.newEntity();
    world.set(stuck, position, .{ .x = 100 });
    world.set(stuck, velocity, .{ .x = 5 });
    world.add(stuck, frozen);

    const q = try world.queryOf(
        .{ position, zecs.in(velocity), zecs.without(frozen) },
        .{ .cache_kind = .auto },
    );
    defer q.deinit();

    // Per table.
    var it = q.iter();
    defer it.deinit();
    var seen: usize = 0;
    while (it.next()) |row| {
        const p, const v = row.fields;
        try std.testing.expectEqual(@as(usize, 1), p.len);
        for (p, v) |*pos, vel| pos.x += vel.x;
        seen += row.count();
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
    try std.testing.expectEqual(@as(f32, 2), world.get(moving, position).?.x);
    try std.testing.expectEqual(@as(f32, 100), world.get(stuck, position).?.x);

    // Per entity, and the read-only term really is const: `v` below is `*const Velocity`.
    var total: f32 = 0;
    q.each(&total, struct {
        fn body(acc: *f32, e: zecs.Entity, p: *Position, v: *const Velocity) void {
            _ = e;
            p.x += v.x;
            acc.* += p.x;
        }
    }.body);
    try std.testing.expectEqual(@as(f32, 4), total);
}

test "an optional term hands back null for the tables that lack it" {
    const zecs = @import("zecs.zig");

    const world = try zecs.World.init();
    defer world.deinit();

    const Position = struct { x: f32 = 0 };
    const Velocity = struct { x: f32 = 0 };

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    const with = world.newEntity();
    world.set(with, position, .{ .x = 0 });
    world.set(with, velocity, .{ .x = 3 });

    const without_v = world.newEntity();
    world.set(without_v, position, .{ .x = 0 });

    const q = try world.queryOf(.{ position, zecs.optional(velocity) }, .{});
    defer q.deinit();

    var matched: usize = 0;
    var with_velocity: usize = 0;
    var it = q.iter();
    defer it.deinit();
    while (it.next()) |row| {
        const p, const maybe_v = row.fields;
        matched += p.len;
        if (maybe_v) |v| {
            with_velocity += v.len;
            for (p, v) |*pos, vel| pos.x += vel.x;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), matched);
    try std.testing.expectEqual(@as(usize, 1), with_velocity);
    try std.testing.expectEqual(@as(f32, 3), world.get(with, position).?.x);
    try std.testing.expectEqual(@as(f32, 0), world.get(without_v, position).?.x);
}

test {
    _ = Error;
    _ = types;
    _ = std;
}
