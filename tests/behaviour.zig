//! What the package does, exercised through the public module only.
//!
//! Nothing here reaches into the package's internals: these tests import `zecs` the way
//! a consumer does, so anything they need that is not exported is a gap in the API
//! rather than something to work around with a private import.
//!
//! flecs's allocator is process-wide and so is the world counter that guards it, which
//! makes the order of these tests part of what they check: the allocator test that runs
//! first is the one that proves installation is refused once a world exists.

const std = @import("std");
const zecs = @import("zecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { value: i32 };
const Depth = struct { level: i32 };
const Player = struct {}; // zero-sized: a tag

//=============================================================================
// A counting allocator
//
// The package can report its own numbers when built with -Dtrack_allocations, but the
// point of these tests is to check that claim rather than repeat it — so they count
// independently, in every optimize mode, from outside.
//=============================================================================

const Counting = struct {
    backing: std.mem.Allocator,
    live_bytes: std.atomic.Value(usize) = .init(0),
    live_blocks: std.atomic.Value(isize) = .init(0),
    served: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        _ = self.live_bytes.fetchAdd(len, .monotonic);
        _ = self.live_blocks.fetchAdd(1, .monotonic);
        _ = self.served.fetchAdd(1, .monotonic);
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(buf, alignment, new_len, ra)) return false;
        _ = self.live_bytes.fetchAdd(new_len, .monotonic);
        _ = self.live_bytes.fetchSub(buf.len, .monotonic);
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(buf, alignment, new_len, ra) orelse return null;
        _ = self.live_bytes.fetchAdd(new_len, .monotonic);
        _ = self.live_bytes.fetchSub(buf.len, .monotonic);
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        _ = self.live_bytes.fetchSub(buf.len, .monotonic);
        _ = self.live_blocks.fetchSub(1, .monotonic);
        self.backing.rawFree(buf, alignment, ra);
    }
};

//=============================================================================
// Allocator injection
//=============================================================================

test "flecs allocates through the injected allocator, and gives it all back" {
    var counting = Counting{ .backing = std.testing.allocator };
    try zecs.setAllocator(counting.allocator());

    const world = try zecs.World.init();

    // Creating a world is thousands of allocations. If any of them had gone to libc
    // instead, this would be zero.
    try std.testing.expect(counting.served.load(.monotonic) > 0);
    try std.testing.expect(counting.live_blocks.load(.monotonic) > 0);

    const position = try world.component(Position, .{});
    for (0..1000) |i| {
        const e = world.newEntity();
        world.set(e, position, .{ .x = @floatFromInt(i), .y = 0 });
    }

    world.deinit();

    // The claim the whole seam rests on: flecs holds nothing afterwards.
    try std.testing.expectEqual(@as(isize, 0), counting.live_blocks.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), counting.live_bytes.load(.monotonic));

    // And the package's own accounting, where it is compiled in, agrees.
    if (zecs.allocationStats()) |stats| {
        try std.testing.expectEqual(@as(usize, 0), stats.live_blocks);
        try std.testing.expectEqual(@as(usize, 0), stats.live_bytes);
    }
}

test "installing an allocator after a world exists is an error, not a crash" {
    try zecs.setAllocator(std.testing.allocator);

    const world = try zecs.World.init();
    defer world.deinit();

    // flecs would accept this and start freeing the world's live blocks through a
    // different allocator. The binding refuses instead.
    var other = Counting{ .backing = std.testing.allocator };
    try std.testing.expectError(
        zecs.Error.WorldAlreadyExists,
        zecs.setAllocator(other.allocator()),
    );
}

test "the allocator can be replaced once no world is left" {
    try zecs.setAllocator(std.testing.allocator);
    {
        const world = try zecs.World.init();
        world.deinit();
    }
    var counting = Counting{ .backing = std.testing.allocator };
    try zecs.setAllocator(counting.allocator());
    {
        const world = try zecs.World.init();
        world.deinit();
    }
    try std.testing.expectEqual(@as(isize, 0), counting.live_blocks.load(.monotonic));
    try zecs.setAllocator(std.testing.allocator);
}

//=============================================================================
// World and entities
//=============================================================================

test "a world can be created and destroyed repeatedly" {
    try zecs.setAllocator(std.testing.allocator);

    for (0..4) |_| {
        const world = try zecs.World.init();
        defer world.deinit();
        try std.testing.expect(!world.shouldQuit());
    }
}

test "a minimal world has no pipeline" {
    try zecs.setAllocator(std.testing.allocator);

    const world = try zecs.World.initMinimal();
    defer world.deinit();

    const e = world.newEntity();
    try std.testing.expect(world.isAlive(e));
}

test "entities are alive until deleted, and recycled ids do not answer for the dead" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const e = world.newEntity();
    try std.testing.expect(world.isAlive(e));

    world.delete(e);
    try std.testing.expect(!world.isAlive(e));

    // flecs recycles the index but bumps the generation, so the old handle stays dead.
    const recycled = world.newEntity();
    try std.testing.expect(world.isAlive(recycled));
    try std.testing.expect(!world.isAlive(e));
}

test "entities can be named, found by name, and parented" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const parent = try world.entity(.{ .name = "parent" });
    const child = try world.entity(.{ .name = "child", .parent = parent });

    try std.testing.expectEqualStrings("parent", world.getName(parent).?);
    try std.testing.expectEqualStrings("child", world.getName(child).?);
    try std.testing.expectEqual(parent, world.getParent(child));
    try std.testing.expectEqual(parent, world.lookup("parent"));
}

//=============================================================================
// Components
//=============================================================================

test "a registered component reports the type's own size and alignment" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    try std.testing.expect(position.asId() != 0);

    // Registering the same type again is the same component, not a second one.
    const again = try world.component(Position, .{});
    try std.testing.expectEqual(position.asId(), again.asId());

    // A name containing dots — which every @typeName does — must not be read as a path.
    const name = world.getName(position.asId()).?;
    try std.testing.expect(std.mem.indexOf(u8, name, "Position") != null);
}

test "add, set, get, getMut, ensure, has and remove round-trip" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const health = try world.component(Health, .{});

    const e = world.newEntity();
    try std.testing.expect(!world.has(e, position));

    world.set(e, position, .{ .x = 1.5, .y = -2.5 });
    try std.testing.expect(world.has(e, position));

    const read = world.get(e, position).?;
    try std.testing.expectEqual(@as(f32, 1.5), read.x);
    try std.testing.expectEqual(@as(f32, -2.5), read.y);

    world.getMut(e, position).?.x = 10;
    world.modified(e, position);
    try std.testing.expectEqual(@as(f32, 10), world.get(e, position).?.x);

    // ensure adds the component when it is missing.
    try std.testing.expect(!world.has(e, health));
    world.ensure(e, health).value = 42;
    try std.testing.expect(world.has(e, health));
    try std.testing.expectEqual(@as(i32, 42), world.get(e, health).?.value);

    world.remove(e, position);
    try std.testing.expect(!world.has(e, position));
    try std.testing.expect(world.get(e, position) == null);
}

test "a zero-sized component is a tag" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const player = try world.component(Player, .{});
    const e = world.newEntity();

    // `set` on a tag adds it; there is nothing to store.
    world.set(e, player, .{});
    try std.testing.expect(world.has(e, player));
}

test "components can be created with several ids at once" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    const e = try world.entity(.{ .add = &.{ position.asId(), velocity.asId() } });
    try std.testing.expect(world.has(e, position));
    try std.testing.expect(world.has(e, velocity));
}

//=============================================================================
// Queries
//=============================================================================

test "a query iterates every matching entity exactly once" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    const with_both = 50;
    const with_one = 30;
    for (0..with_both) |i| {
        const e = world.newEntity();
        world.set(e, position, .{ .x = @floatFromInt(i), .y = 0 });
        world.set(e, velocity, .{ .x = 1, .y = 0 });
    }
    for (0..with_one) |i| {
        const e = world.newEntity();
        world.set(e, position, .{ .x = @floatFromInt(i), .y = 0 });
    }

    var query = try world.query(.{ .terms = &.{
        .{ .id = position.asId() },
        .{ .id = velocity.asId() },
    } });
    defer query.deinit();

    var seen: usize = 0;
    var sum: f32 = 0;
    var it = query.iter();
    defer it.deinit();
    while (it.next()) |row| {
        const positions = row.fieldSelf(Position, 0);
        const velocities = row.fieldSelf(Velocity, 1);
        try std.testing.expectEqual(positions.len, velocities.len);
        for (positions) |p| sum += p.x;
        seen += row.count();
    }

    try std.testing.expectEqual(@as(usize, with_both), seen);
    try std.testing.expectEqual(@as(f32, with_both * (with_both - 1) / 2), sum);
}

test "an optional term reports whether it matched" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    const moving = world.newEntity();
    world.set(moving, position, .{ .x = 0, .y = 0 });
    world.set(moving, velocity, .{ .x = 1, .y = 1 });

    const still = world.newEntity();
    world.set(still, position, .{ .x = 5, .y = 5 });

    var query = try world.query(.{ .terms = &.{
        .{ .id = position.asId() },
        .{ .id = velocity.asId(), .oper = .optional },
    } });
    defer query.deinit();

    var with_velocity: usize = 0;
    var without_velocity: usize = 0;
    var it = query.iter();
    defer it.deinit();
    while (it.next()) |row| {
        if (row.isSet(1)) {
            with_velocity += row.count();
            try std.testing.expect(row.field(Velocity, 1) != null);
        } else {
            without_velocity += row.count();
        }
    }

    try std.testing.expectEqual(@as(usize, 1), with_velocity);
    try std.testing.expectEqual(@as(usize, 1), without_velocity);
}

test "a not term excludes" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const player = try world.component(Player, .{});

    const npc = world.newEntity();
    world.set(npc, position, .{ .x = 0, .y = 0 });

    const hero = world.newEntity();
    world.set(hero, position, .{ .x = 1, .y = 1 });
    world.add(hero, player);

    var query = try world.query(.{ .terms = &.{
        .{ .id = position.asId() },
        .{ .id = player.asId(), .oper = .not },
    } });
    defer query.deinit();

    var matched: usize = 0;
    var it = query.iter();
    defer it.deinit();
    while (it.next()) |row| {
        matched += row.count();
        for (row.entities()) |e| try std.testing.expectEqual(npc, e);
    }
    try std.testing.expectEqual(@as(usize, 1), matched);
}

test "each walks one component without compiling a query" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const health = try world.component(Health, .{});
    for (0..10) |i| {
        const e = world.newEntity();
        world.set(e, health, .{ .value = @intCast(i) });
    }

    var total: i32 = 0;
    var seen: usize = 0;
    var it = world.each(health);
    defer it.deinit();
    while (it.next()) |row| {
        for (row.fieldSelf(Health, 0)) |h| total += h.value;
        seen += row.count();
    }

    try std.testing.expectEqual(@as(usize, 10), seen);
    try std.testing.expectEqual(@as(i32, 45), total);
}

test "breaking out of an iteration early releases it" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    for (0..100) |i| {
        const e = world.newEntity();
        world.set(e, position, .{ .x = @floatFromInt(i), .y = 0 });
        // Give the entities different archetypes so iteration spans several tables.
        if (i % 2 == 0) world.addId(e, world.newEntity());
    }

    var query = try world.query(.{ .terms = &.{.{ .id = position.asId() }} });
    defer query.deinit();

    {
        var it = query.iter();
        defer it.deinit(); // the early break is why this has to be safe
        while (it.next()) |row| {
            _ = row;
            break;
        }
    }

    // Iterating to completion afterwards must still work — the first loop released its
    // iterator exactly once.
    var seen: usize = 0;
    var it = query.iter();
    defer it.deinit();
    while (it.next()) |row| seen += row.count();
    try std.testing.expectEqual(@as(usize, 100), seen);
}

//=============================================================================
// Traversal
//=============================================================================

test "an Up term reads a component from the nearest ancestor that has it" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const health = try world.component(Health, .{});

    const parent = world.newEntity();
    world.set(parent, health, .{ .value = 7 });

    var children: [3]zecs.Entity = undefined;
    for (&children, 0..) |*child, i| {
        child.* = world.newEntity();
        world.set(child.*, position, .{ .x = @floatFromInt(i), .y = 0 });
        world.addPair(child.*, zecs.Builtin.child_of.id(), parent);
    }

    var query = try world.query(.{ .terms = &.{
        .{ .id = position.asId() },
        .{
            .id = health.asId(),
            .src = .{ .id = zecs.Up },
            .trav = zecs.Builtin.child_of.id(),
        },
    } });
    defer query.deinit();

    var matched: usize = 0;
    var it = query.iter();
    defer it.deinit();
    while (it.next()) |row| {
        matched += row.count();

        // The parent's health is one value shared by the whole table, not an array of
        // them — the case a binding that ignores `is_self` reads out of bounds.
        try std.testing.expect(!row.isSelf(1));
        try std.testing.expectEqual(@as(usize, 1), row.field(Health, 1).?.len);
        try std.testing.expectEqual(@as(i32, 7), row.fieldShared(Health, 1).?.value);
        try std.testing.expectEqual(parent, row.fieldSrc(1));

        // The self term is per-entity, and still sized by the entity count.
        try std.testing.expect(row.isSelf(0));
        try std.testing.expectEqual(row.count(), row.fieldSelf(Position, 0).len);
    }
    try std.testing.expectEqual(@as(usize, children.len), matched);
}

test "a Cascade term visits parents before their children" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const depth = try world.component(Depth, .{});
    const child_of = zecs.Builtin.child_of.id();

    // A chain four deep, each level in its own table.
    const root = world.newEntity();
    world.set(root, depth, .{ .level = 0 });

    var previous = root;
    for (1..4) |level| {
        const e = world.newEntity();
        world.set(e, depth, .{ .level = @intCast(level) });
        world.addPair(e, child_of, previous);
        previous = e;
    }

    // The canonical hierarchy query: the entity's own value, plus its parent's, with
    // Cascade asking flecs to order the tables so a parent is always iterated before
    // anything that inherits from it. This is what makes a single pass enough to
    // propagate transforms down a tree.
    var query = try world.query(.{ .terms = &.{
        .{ .id = depth.asId() },
        .{
            .id = depth.asId(),
            .src = .{ .id = zecs.Cascade | zecs.Up },
            .trav = child_of,
            .oper = .optional,
        },
    } });
    defer query.deinit();

    var visited: [4]i32 = undefined;
    var count: usize = 0;
    var it = query.iter();
    defer it.deinit();
    while (it.next()) |row| {
        for (row.fieldSelf(Depth, 0)) |d| {
            visited[count] = d.level;
            count += 1;
        }
        // The root has no parent, so its optional parent term is unset.
        if (row.isSet(1)) {
            const parent_depth = row.fieldShared(Depth, 1).?;
            try std.testing.expectEqual(row.fieldSelf(Depth, 0)[0].level - 1, parent_depth.level);
        }
    }

    try std.testing.expectEqual(@as(usize, 4), count);
    for (visited[0..count], 0..) |level, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i)), level);
    }
}

//=============================================================================
// Observers
//=============================================================================

var observed_count: u32 = 0;
var observed_value: f32 = 0;

fn onPositionSet(it: *zecs.Iter) void {
    for (it.fieldSelf(Position, 0)) |p| {
        observed_count += 1;
        observed_value = p.x;
    }
}

test "an observer fires when a component is set" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});

    observed_count = 0;
    observed_value = 0;

    _ = try world.observer(.{
        .name = "OnPositionSet",
        .query = .{ .terms = &.{.{ .id = position.asId() }} },
        .events = &.{zecs.Builtin.on_set.id()},
        .callback = zecs.callback(onPositionSet),
    });

    const e = world.newEntity();
    world.set(e, position, .{ .x = 3, .y = 4 });
    try std.testing.expectEqual(@as(u32, 1), observed_count);
    try std.testing.expectEqual(@as(f32, 3), observed_value);

    world.set(e, position, .{ .x = 9, .y = 9 });
    try std.testing.expectEqual(@as(u32, 2), observed_count);
    try std.testing.expectEqual(@as(f32, 9), observed_value);

    // A component the observer does not watch must not wake it.
    const health = try world.component(Health, .{});
    world.set(e, health, .{ .value = 1 });
    try std.testing.expectEqual(@as(u32, 2), observed_count);
}

//=============================================================================
// Systems
//=============================================================================

var system_runs: u32 = 0;

fn moveSystem(it: *zecs.Iter) void {
    // deltaTime is `ecs_ftime_t`, which the build can widen to f64. Casting rather than
    // assuming is what makes this test compile under -Dftime_t=fp64 as well.
    const dt: f32 = @floatCast(it.deltaTime());
    const positions = it.fieldSelf(Position, 0);
    const velocities = it.fieldSelf(Velocity, 1);
    for (positions, velocities) |*p, v| {
        p.x += v.x * dt;
        p.y += v.y * dt;
    }
    system_runs += 1;
}

test "a system runs from progress and sees its delta time" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    system_runs = 0;
    _ = try world.system(.{
        .name = "Move",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = &.{
            .{ .id = position.asId(), .inout = .read_write },
            .{ .id = velocity.asId(), .inout = .read },
        } },
        .callback = zecs.callback(moveSystem),
    });

    const e = world.newEntity();
    world.set(e, position, .{ .x = 0, .y = 0 });
    world.set(e, velocity, .{ .x = 2, .y = 4 });

    _ = world.progress(0.5);
    try std.testing.expectEqual(@as(u32, 1), system_runs);
    try std.testing.expectEqual(@as(f32, 1), world.get(e, position).?.x);
    try std.testing.expectEqual(@as(f32, 2), world.get(e, position).?.y);

    _ = world.progress(0.5);
    try std.testing.expectEqual(@as(f32, 2), world.get(e, position).?.x);
}

//=============================================================================
// The typed spec
//
// The same system, built from one tuple instead of a term list plus a set of field
// indices that has to agree with it.
//=============================================================================

const Movers = struct {
    zecs.Component(Position),
    zecs.In(zecs.Component(Velocity)),
};

var typed_system_runs: u32 = 0;

fn moveTyped(row: zecs.RowOf(Movers)) void {
    const dt: f32 = @floatCast(row.deltaTime());
    const positions, const velocities = row.fields;
    for (positions, velocities) |*p, v| {
        p.x += v.x * dt;
        p.y += v.y * dt;
    }
    typed_system_runs += 1;
}

test "a system built from a typed spec reads the components the spec named" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});
    const movers: Movers = .{ position, zecs.in(velocity) };

    typed_system_runs = 0;
    _ = try world.system(.{
        .name = "MoveTyped",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = &zecs.SpecOf(Movers).build(movers) },
        .callback = zecs.rowCallback(Movers, moveTyped),
    });

    const e = world.newEntity();
    world.set(e, position, .{ .x = 0, .y = 0 });
    world.set(e, velocity, .{ .x = 2, .y = 4 });

    _ = world.progress(0.5);
    try std.testing.expectEqual(@as(u32, 1), typed_system_runs);
    try std.testing.expectEqual(@as(f32, 1), world.get(e, position).?.x);
    try std.testing.expectEqual(@as(f32, 2), world.get(e, position).?.y);
}

test "a typed query hands back slices of the type the handle carried" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});
    const health = try world.component(Health, .{});
    const player = try world.component(Player, .{});

    // Two entities in two different tables, so the loop below really does run twice.
    const a = world.newEntity();
    world.set(a, position, .{ .x = 1, .y = 1 });
    world.set(a, velocity, .{ .x = 1, .y = 0 });

    const b = world.newEntity();
    world.set(b, position, .{ .x = 10, .y = 10 });
    world.set(b, velocity, .{ .x = 2, .y = 0 });
    world.set(b, health, .{ .value = 7 });

    // And one the `without` term must keep out.
    const excluded = world.newEntity();
    world.set(excluded, position, .{ .x = 500, .y = 0 });
    world.set(excluded, velocity, .{ .x = 1, .y = 0 });
    world.add(excluded, player);

    const q = try world.queryOf(
        .{ position, zecs.in(velocity), zecs.optional(health), zecs.without(player) },
        .{ .cache_kind = .auto },
    );
    defer q.deinit();

    var tables: usize = 0;
    var with_health: usize = 0;
    var it = q.iter();
    defer it.deinit();
    while (it.next()) |row| {
        // Three data terms out of four: `without` constrains and carries nothing.
        const p, const v, const maybe_h = row.fields;
        for (p, v) |*pos, vel| pos.x += vel.x;
        if (maybe_h) |h| with_health += h.len;
        tables += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), tables);
    try std.testing.expectEqual(@as(usize, 1), with_health);
    try std.testing.expectEqual(@as(f32, 2), world.get(a, position).?.x);
    try std.testing.expectEqual(@as(f32, 12), world.get(b, position).?.x);
    try std.testing.expectEqual(@as(f32, 500), world.get(excluded, position).?.x);

    // And per entity, with the optional term arriving as a nullable pointer.
    var sum: f32 = 0;
    var healthy: u32 = 0;
    const Acc = struct { sum: *f32, healthy: *u32 };
    q.each(Acc{ .sum = &sum, .healthy = &healthy }, struct {
        fn body(acc: Acc, e: zecs.Entity, p: *Position, v: *const Velocity, h: ?*Health) void {
            _ = e;
            _ = v;
            acc.sum.* += p.x;
            if (h != null) acc.healthy.* += 1;
        }
    }.body);
    try std.testing.expectEqual(@as(f32, 14), sum);
    try std.testing.expectEqual(@as(u32, 1), healthy);
}

//=============================================================================
// Ordering and grouping
//
// Both are properties of the query cache, and both were unreachable from the typed
// layer: a query could match the right entities and hand them back in an order nothing
// in the program chose.
//=============================================================================

test "order_by delivers the matched entities in the order the comparator asks for" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const depth = try world.component(Depth, .{});

    for ([_]i32{ 3, 1, 2 }) |level| {
        const e = world.newEntity();
        world.set(e, depth, .{ .level = level });
    }

    const q = try world.queryOf(.{depth}, .{
        .order_by = .{
            .component = depth.asId(),
            .compare = zecs.orderBy(Depth, struct {
                fn cmp(_: zecs.Entity, a: *const Depth, _: zecs.Entity, b: *const Depth) std.math.Order {
                    return std.math.order(a.level, b.level);
                }
            }.cmp),
        },
    });
    defer q.deinit();

    var seen: [3]i32 = .{ 0, 0, 0 };
    var n: usize = 0;
    var it = q.iter();
    defer it.deinit();
    while (it.next()) |row| {
        const levels = row.fields[0];
        for (levels) |d| {
            seen[n] = d.level;
            n += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, &seen);

    // Sorting forces a cache, whatever the cache kind asked for.
    try std.testing.expect(q.query.cacheKind() != .none);
}

test "group_by splits the results, and one group can be iterated alone" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const faction = try world.entity(.{ .name = "Faction" });
    const red = try world.entity(.{ .name = "Red" });
    const blue = try world.entity(.{ .name = "Blue" });

    const a = world.newEntity();
    world.set(a, position, .{ .x = 1, .y = 0 });
    world.addPair(a, faction, red);

    const b = world.newEntity();
    world.set(b, position, .{ .x = 2, .y = 0 });
    world.addPair(b, faction, blue);

    const cc = world.newEntity();
    world.set(cc, position, .{ .x = 4, .y = 0 });
    world.addPair(cc, faction, red);

    const q = try world.queryOf(
        .{ position, zecs.withId(zecs.pair(faction, zecs.Builtin.wildcard.id())) },
        .{ .group_by = .{ .id = faction } },
    );
    defer q.deinit();

    // Every group, then one.
    var total: f32 = 0;
    var it = q.iter();
    defer it.deinit();
    while (it.next()) |row| for (row.fields[0]) |p| {
        total += p.x;
    };
    try std.testing.expectEqual(@as(f32, 7), total);

    var reds: f32 = 0;
    var red_it = q.iterGroup(red);
    defer red_it.deinit();
    while (red_it.next()) |row| for (row.fields[0]) |p| {
        reds += p.x;
    };
    try std.testing.expectEqual(@as(f32, 5), reds);

    // And flecs knows the group exists, which is what `on_group_create` hangs off.
    try std.testing.expect(q.query.groupInfo(red) != null);
    try std.testing.expect(q.query.groupInfo(999_999) == null);
}

test "a pipeline orders the systems of one phase instead of leaving them to table order" {
    try zecs.setAllocator(std.testing.allocator);
    if (!zecs.options.addon_pipeline) return error.SkipZigTest;

    // The defect this guards against is a pipeline that matches the right systems and
    // runs them in whatever order their tables happen to be in. `PipelineDesc.toC`
    // installs flecs's own tie-break — entity id, which is creation order — when the
    // caller sets none, so the descriptor handed to flecs always carries a comparator.
    const built = try (zecs.pipeline.PipelineDesc{}).toC(0);
    try std.testing.expect(built.query.order_by_callback != null);

    // And a caller who chooses an ordering keeps it.
    const mine = zecs.orderByEntity(struct {
        fn cmp(e1: zecs.Entity, e2: zecs.Entity) std.math.Order {
            return std.math.order(e2, e1);
        }
    }.cmp);
    const custom = try (zecs.pipeline.PipelineDesc{
        .query = .{ .options = .{ .order_by = .{ .compare = mine } } },
    }).toC(0);
    try std.testing.expectEqual(mine, custom.query.order_by_callback);
}

test "same-phase systems run in creation order" {
    try zecs.setAllocator(std.testing.allocator);
    if (!zecs.options.addon_pipeline) return error.SkipZigTest;

    const world = try zecs.World.init();
    defer world.deinit();

    phase_order_log = .{ 0, 0, 0 };
    phase_order_n = 0;

    const first = try world.system(.{
        .name = "First",
        .phase = zecs.Builtin.on_update.id(),
        .callback = zecs.callback(logFirst),
    });
    const second = try world.system(.{
        .name = "Second",
        .phase = zecs.Builtin.on_update.id(),
        .callback = zecs.callback(logSecond),
    });
    // The contract is entity-id order, and flecs hands out ascending ids, so the system
    // created first is the one that runs first.
    try std.testing.expect(first < second);

    _ = world.progress(0);
    try std.testing.expectEqual(@as(usize, 2), phase_order_n);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, phase_order_log[0..2]);
}

var phase_order_log: [3]u8 = .{ 0, 0, 0 };
var phase_order_n: usize = 0;

fn logFirst(_: *zecs.Iter) void {
    phase_order_log[phase_order_n] = 1;
    phase_order_n += 1;
}

fn logSecond(_: *zecs.Iter) void {
    phase_order_log[phase_order_n] = 2;
    phase_order_n += 1;
}

test "a system with no phase runs only when asked" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    system_runs = 0;
    const manual = try world.system(.{
        .name = "ManualMove",
        .query = .{ .terms = &.{
            .{ .id = position.asId() },
            .{ .id = velocity.asId() },
        } },
        .callback = zecs.callback(moveSystem),
    });

    const e = world.newEntity();
    world.set(e, position, .{ .x = 0, .y = 0 });
    world.set(e, velocity, .{ .x = 1, .y = 0 });

    _ = world.progress(1.0);
    try std.testing.expectEqual(@as(u32, 0), system_runs);

    _ = world.run(manual, 1.0, null);
    try std.testing.expectEqual(@as(u32, 1), system_runs);
    try std.testing.expectEqual(@as(f32, 1), world.get(e, position).?.x);
}

//=============================================================================
// Threading
//=============================================================================

var threaded_rows: std.atomic.Value(u32) = .init(0);

fn threadedSystem(it: *zecs.Iter) void {
    const positions = it.fieldSelf(Position, 0);
    const velocities = it.fieldSelf(Velocity, 1);
    for (positions, velocities) |*p, v| p.x += v.x;
    _ = threaded_rows.fetchAdd(@intCast(positions.len), .monotonic);
}

test "a multi-threaded system covers every entity exactly once" {
    var counting = Counting{ .backing = std.testing.allocator };
    try zecs.setAllocator(counting.allocator());

    const world = try zecs.World.init();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    const entity_count = 4000;
    for (0..entity_count) |_| {
        const e = world.newEntity();
        world.set(e, position, .{ .x = 0, .y = 0 });
        world.set(e, velocity, .{ .x = 1, .y = 0 });
    }

    threaded_rows.store(0, .monotonic);
    _ = try world.system(.{
        .name = "ThreadedMove",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = &.{
            .{ .id = position.asId(), .inout = .read_write },
            .{ .id = velocity.asId(), .inout = .read },
        } },
        .callback = zecs.callback(threadedSystem),
        .multi_threaded = true,
    });

    // Worker threads allocate through the injected allocator, so this also exercises
    // the seam from several threads at once.
    world.setThreads(4);

    _ = world.progress(1.0);
    _ = world.progress(1.0);

    try std.testing.expectEqual(@as(u32, entity_count * 2), threaded_rows.load(.monotonic));

    var it = world.each(position);
    defer it.deinit();
    while (it.next()) |row| {
        for (row.fieldSelf(Position, 0)) |p| {
            try std.testing.expectEqual(@as(f32, 2), p.x);
        }
    }

    world.deinit();
    try std.testing.expectEqual(@as(isize, 0), counting.live_blocks.load(.monotonic));

    try zecs.setAllocator(std.testing.allocator);
}

//=============================================================================
// Reflection
//
// A schema derived from a Zig type is only real if flecs can read a value back through
// it, so these go the whole way round: register a type, set it on an entity, serialise
// it to JSON through flecs, and parse JSON back into it.
//
// Both halves need addons. The behaviour suite already only builds with the system and
// pipeline addons, but meta and json are separate options, so each test states what it
// needs. The check has to wrap the body rather than return early from it: a build
// without the addons must not analyse code that names their symbols.
//=============================================================================

const reflection = zecs.options.addon_meta and zecs.options.addon_json;

const Facing = enum(i32) { north = 0, east = 90, south = 180, west = 270 };

const Vec2 = struct { x: f32, y: f32 };

const Flags = packed struct(u32) {
    visible: bool,
    frozen: bool,
    _rest: u30,
};

const Body = struct {
    origin: Vec2,
    facing: Facing,
    hits: [3]i32,
    alive: bool,
    flags: Flags,
    owner: zecs.Entity,

    /// `zecs.Entity` is a `u64`, so the type alone cannot say this is a reference.
    pub const zecs_entity_fields = .{"owner"};
};

/// Frees a string flecs allocated. flecs hands ownership of every `char*` it returns to
/// the caller, and the allocator that made it is the one installed on the OS API.
fn freeFlecsString(text: [*:0]u8) void {
    zecs.c.core.ecs_os_api.free_.?(@ptrCast(text));
}

test "a derived schema serialises a nested Zig struct to JSON" {
    if (comptime reflection) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        const body = try world.component(Body, .{});
        const schema = try zecs.meta.register(world, body);
        try std.testing.expectEqual(body.asId(), schema);

        const captain = try world.entity(.{ .name = "captain" });
        const e = world.newEntity();
        world.set(e, body, .{
            .origin = .{ .x = 1.5, .y = -2.25 },
            .facing = .north,
            .hits = .{ 3, 5, 8 },
            .alive = true,
            .flags = .{ .visible = true, .frozen = false, ._rest = 0 },
            .owner = captain,
        });

        const text = zecs.c.core.ecs_ptr_to_json(world.raw, schema, world.get(e, body).?) orelse
            return error.SerializeFailed;
        defer freeFlecsString(text);

        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            std.mem.span(text),
            .{},
        );
        defer parsed.deinit();
        const value = parsed.value.object;

        // A nested struct is an object, with the member names Zig gave it.
        const origin = value.get("origin").?.object;
        try std.testing.expectEqual(@as(f64, 1.5), origin.get("x").?.float);
        try std.testing.expectEqual(@as(f64, -2.25), origin.get("y").?.float);

        // An enum is its constant's name. `north` is zero, which is the value flecs
        // reads as "unset" in its own descriptor and auto-numbers away from.
        try std.testing.expectEqualStrings("north", value.get("facing").?.string);

        const hits = value.get("hits").?.array.items;
        try std.testing.expectEqual(@as(usize, 3), hits.len);
        try std.testing.expectEqual(@as(i64, 3), hits[0].integer);
        try std.testing.expectEqual(@as(i64, 8), hits[2].integer);

        try std.testing.expect(value.get("alive").?.bool);

        // A bitmask is the names of the bits that are set.
        try std.testing.expectEqualStrings("visible", value.get("flags").?.string);

        // The annotated member is an entity, so it serialises as the entity's path
        // rather than as the integer underneath it. That is the difference between the
        // Explorer showing a link and showing a number.
        try std.testing.expectEqualStrings("captain", value.get("owner").?.string);
    }
}

test "a derived schema parses JSON back into a Zig struct" {
    if (comptime reflection) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        const body = try world.component(Body, .{});
        const schema = try zecs.meta.register(world, body);
        _ = try world.entity(.{ .name = "quartermaster" });

        var parsed: Body = std.mem.zeroes(Body);
        const rest = zecs.c.json.ecs_ptr_from_json(world.raw, schema, &parsed,
            \\{"origin": {"x": 10.5, "y": -4}, "facing": "west", "hits": [7, 11, 13],
            \\ "alive": true, "flags": "frozen", "owner": "quartermaster"}
        , &.{});
        try std.testing.expect(rest != null);

        try std.testing.expectEqual(@as(f32, 10.5), parsed.origin.x);
        try std.testing.expectEqual(@as(f32, -4), parsed.origin.y);
        try std.testing.expectEqual(Facing.west, parsed.facing);
        try std.testing.expectEqual([3]i32{ 7, 11, 13 }, parsed.hits);
        try std.testing.expect(parsed.alive);
        try std.testing.expect(parsed.flags.frozen);
        try std.testing.expect(!parsed.flags.visible);
        try std.testing.expectEqual(world.lookup("quartermaster"), parsed.owner);
    }
}

test "the derived members carry the offsets and types the Zig type has" {
    if (comptime reflection) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        const body = try world.component(Body, .{});
        const schema = try zecs.meta.register(world, body);

        // Offsets come from @offsetOf rather than from flecs recomputing a layout, so
        // they hold even where Zig has moved a field to close a padding hole.
        inline for (.{ "origin", "facing", "hits", "alive", "flags", "owner" }) |name| {
            const member = zecs.c.meta.ecs_struct_get_member(world.raw, schema, name).?;
            try std.testing.expectEqual(@as(i32, @offsetOf(Body, name)), member.offset);
        }

        // The annotated member is flecs's entity type, not the u64 it is made of.
        const owner = zecs.c.meta.ecs_struct_get_member(world.raw, schema, "owner").?;
        try std.testing.expectEqual(zecs.c.core.FLECS_IDecs_entity_tID_, owner.type);

        // An array field is an inline array of its element type.
        const hits = zecs.c.meta.ecs_struct_get_member(world.raw, schema, "hits").?;
        try std.testing.expectEqual(@as(i32, 3), hits.count);
        try std.testing.expectEqual(zecs.c.core.FLECS_IDecs_i32_tID_, hits.type);
    }
}

test "a nested type used by two components is registered once" {
    if (comptime reflection) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        const Origin = struct { at: Vec2 };
        const Destination = struct { at: Vec2 };

        const origin = try world.component(Origin, .{});
        const destination = try world.component(Destination, .{});
        _ = try zecs.meta.register(world, origin);
        _ = try zecs.meta.register(world, destination);

        // Both members point at the one entity Vec2 registered under, which is also
        // what asking for it directly returns.
        const vec2 = try zecs.meta.typeId(world, Vec2);
        const from = zecs.c.meta.ecs_struct_get_member(world.raw, origin.asId(), "at").?;
        const to = zecs.c.meta.ecs_struct_get_member(world.raw, destination.asId(), "at").?;
        try std.testing.expectEqual(vec2, from.type);
        try std.testing.expectEqual(vec2, to.type);
    }
}

test "registering the same type twice changes nothing and allocates nothing" {
    if (comptime reflection) {
        var counting = Counting{ .backing = std.testing.allocator };
        try zecs.setAllocator(counting.allocator());

        const world = try zecs.World.init();

        const body = try world.component(Body, .{});
        const first = try zecs.meta.register(world, body);

        const before = counting.served.load(.monotonic);
        const second = try zecs.meta.register(world, body);
        try std.testing.expectEqual(first, second);

        // The memo is flecs's own: the type already carries EcsType, so the second call
        // reads one component and returns without building anything.
        try std.testing.expectEqual(before, counting.served.load(.monotonic));

        var members: i32 = 0;
        while (zecs.c.meta.ecs_struct_get_nth_member(world.raw, first, members) != null) {
            members += 1;
        }
        try std.testing.expectEqual(@as(i32, @typeInfo(Body).@"struct".fields.len), members);

        world.deinit();
        try std.testing.expectEqual(@as(isize, 0), counting.live_blocks.load(.monotonic));

        try zecs.setAllocator(std.testing.allocator);
    }
}

test "a C string member is flecs's string type" {
    if (comptime reflection) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        // Only read back here. flecs frees a string member with ecs_os_free before
        // assigning to it, so a Zig-owned string must never be the target of a parse.
        const Label = struct { text: ?[*:0]const u8, weight: u8 };

        const label = try world.component(Label, .{});
        const schema = try zecs.meta.register(world, label);

        const value = Label{ .text = "starboard", .weight = 3 };
        const text = zecs.c.core.ecs_ptr_to_json(world.raw, schema, &value) orelse
            return error.SerializeFailed;
        defer freeFlecsString(text);

        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            std.mem.span(text),
            .{},
        );
        defer parsed.deinit();

        try std.testing.expectEqualStrings("starboard", parsed.value.object.get("text").?.string);
        try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("weight").?.integer);
    }
}

//=============================================================================
// The world, entities and ids
//=============================================================================

const Damage = struct { amount: i32 };

fn deferredFailure(world: zecs.World, position: zecs.Component(Position), e: zecs.Entity) !void {
    var scope = world.deferScope();
    defer scope.end();

    world.set(e, position, .{ .x = 1, .y = 0 });
    return error.Boom;
}

test "a defer scope closes once, and closes on the way out of an error" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const e = world.newEntity();

    try std.testing.expectError(error.Boom, deferredFailure(world, position, e));
    try std.testing.expect(!world.isDeferred());
    // The command queued before the failure was still flushed by the scope's end.
    try std.testing.expectEqual(@as(f32, 1), world.get(e, position).?.x);

    // A second `end` on the inner scope must not decrement flecs's defer count again:
    // if it did, the outer scope's queue would flush here instead of at its own end.
    const other = world.newEntity();
    var outer = world.deferScope();
    var inner = world.deferScope();
    inner.end();
    inner.end();

    world.set(other, position, .{ .x = 5, .y = 0 });
    try std.testing.expect(world.isDeferred());
    try std.testing.expect(world.get(other, position) == null);

    outer.end();
    try std.testing.expect(!world.isDeferred());
    try std.testing.expectEqual(@as(f32, 5), world.get(other, position).?.x);
}

test "suspending the queue lets an operation through without flushing it" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const health = try world.component(Health, .{});
    const queued = world.newEntity();
    const immediate = world.newEntity();

    var d = world.deferScope();

    world.set(queued, position, .{ .x = 1, .y = 0 });
    try std.testing.expect(world.get(queued, position) == null);

    var s = world.suspendScope();
    world.set(immediate, health, .{ .value = 7 });
    try std.testing.expectEqual(@as(i32, 7), world.get(immediate, health).?.value);
    s.end();

    // Still deferred, and the queue from before the suspension survived it.
    try std.testing.expect(world.get(queued, position) == null);
    d.end();
    try std.testing.expectEqual(@as(f32, 1), world.get(queued, position).?.x);
}

test "a readonly world is written through a stage and merged at the end" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const e = world.newEntity();

    // Stage counts have no wrapper: nothing about the call needs one.
    zecs.c.world.ecs_set_stage_count(world.raw, 2);
    try std.testing.expectError(zecs.Error.StageOutOfRange, world.stage(2));
    try std.testing.expectError(zecs.Error.StageOutOfRange, world.stage(-1));

    const stage = try world.stage(1);
    try std.testing.expect(!zecs.c.world.ecs_stage_is_readonly(world.raw));

    var readonly = world.readonlyScope(false);
    try std.testing.expect(zecs.c.world.ecs_stage_is_readonly(world.raw));

    // A stage is a world for every purpose except its lifetime.
    stage.set(e, position, .{ .x = 3, .y = 4 });
    try std.testing.expect(world.get(e, position) == null);

    readonly.end();
    try std.testing.expectEqual(@as(f32, 3), world.get(e, position).?.x);
    try std.testing.expect(!zecs.c.world.ecs_stage_is_readonly(world.raw));
}

test "a frame scope carries its delta time and counts the frame" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const before = zecs.c.world.ecs_get_world_info(world.raw).frame_count_total;

    var f = world.frame(0.25);
    try std.testing.expectEqual(@as(zecs.c.core.ecs_ftime_t, 0.25), f.delta_time);
    f.end();
    f.end();

    var measured = world.frame(0);
    // Handed zero, flecs times the frame itself rather than passing zero on.
    try std.testing.expect(measured.delta_time > 0);
    measured.end();

    try std.testing.expectEqual(
        before + 2,
        zecs.c.world.ecs_get_world_info(world.raw).frame_count_total,
    );
}

test "entities are created in bulk, with their component values" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const player = try world.component(Player, .{});
    const position = try world.component(Position, .{});

    {
        // The returned array is flecs's own, so it is copied before anything else
        // touches the world.
        var made: [5]zecs.Entity = undefined;
        @memcpy(&made, try world.bulkNew(player, 5));

        for (made) |e| {
            try std.testing.expect(world.isAlive(e));
            try std.testing.expect(world.has(e, player));
        }
        try std.testing.expectEqual(@as(i32, 5), zecs.c.entity.ecs_count_id(world.raw, player.asId()));
    }

    var values = [_]Position{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 3 } };
    const ids = [_]zecs.Id{position.asId()};
    const columns = [_]?*anyopaque{@ptrCast(&values)};

    var made: [3]zecs.Entity = undefined;
    @memcpy(&made, try world.bulkInit(.{ .count = 3, .ids = &ids, .data = &columns }));

    for (made, 0..) |e, i| {
        try std.testing.expectEqual(@as(f32, @floatFromInt(i + 1)), world.get(e, position).?.x);
    }

    // One value column per id, and flecs would read off the end of a short one.
    const short = [_]?*anyopaque{};
    try std.testing.expectError(zecs.Error.BulkArrayMismatch, world.bulkInit(.{
        .count = 3,
        .ids = &ids,
        .data = &short,
    }));

    const too_many = [_]zecs.Id{1} ** (zecs.c.core.FLECS_ID_DESC_MAX + 1);
    try std.testing.expectError(zecs.Error.TooManyIds, world.bulkInit(.{
        .count = 1,
        .ids = &too_many,
    }));
}

test "paths are written, resolved and created with any separator" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const root = try world.entity(.{ .name = "root" });
    const leaf = try world.entity(.{ .name = "leaf", .parent = root });

    {
        const p = world.pathOf(leaf, .{}).?;
        defer p.deinit();
        try std.testing.expectEqualStrings("root.leaf", p.value);
    }
    {
        const p = world.pathOf(leaf, .{ .sep = "/" }).?;
        defer p.deinit();
        try std.testing.expectEqualStrings("root/leaf", p.value);
    }
    {
        const p = world.pathOf(leaf, .{ .from = root }).?;
        defer p.deinit();
        try std.testing.expectEqualStrings("leaf", p.value);
    }
    {
        // An entity's path to itself is empty — and still a string flecs allocated.
        const p = world.pathOf(root, .{ .from = root }).?;
        defer p.deinit();
        try std.testing.expectEqualStrings("", p.value);
    }

    try std.testing.expectEqual(leaf, world.lookupPath("root/leaf", .{ .sep = "/" }));
    try std.testing.expectEqual(leaf, world.lookupPath("leaf", .{ .from = root }));
    try std.testing.expectEqual(@as(zecs.Entity, 0), world.lookupPath("root/nope", .{ .sep = "/" }));

    const made = try world.newFromPath("a.b.c", .{});
    try std.testing.expectEqualStrings("c", world.getName(made).?);
    try std.testing.expectEqual(made, world.lookupPath("a.b.c", .{}));
    // Intermediate entities are created along the way.
    try std.testing.expect(world.lookupPath("a.b", .{}) != 0);
    // And asking again finds the same one rather than making a second.
    try std.testing.expectEqual(made, try world.newFromPath("a.b.c", .{}));

    // `lookup` is the literal one, and is the half that matches how this package writes
    // names: a component is registered under `@typeName(T)`, dots and all, and looking
    // that up as a PATH asks for a `Position` inside a scope called `main` — which is
    // not what was created, and used to answer 0.
    const dotted = try world.entity(.{ .name = "one.two" });
    try std.testing.expectEqual(dotted, world.lookup("one.two"));
    try std.testing.expectEqual(@as(zecs.Entity, 0), world.lookupPath("one.two", .{}));
    try std.testing.expectEqual(@as(zecs.Entity, 0), world.lookup("a.b.c"));

    const position = try world.component(Position, .{});
    try std.testing.expectEqual(position.asId(), world.lookup(@typeName(Position)));
}

test "a scope guard parents what is made inside it and restores the old scope" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const outer = try world.entity(.{ .name = "outer" });
    const inner_parent = try world.entity(.{ .name = "inner", .parent = outer });

    var s = world.scope(outer);
    const first = try world.entity(.{ .name = "first" });

    var nested = world.scope(inner_parent);
    const second = try world.entity(.{ .name = "second" });
    nested.end();
    nested.end();

    // The nested guard put the outer scope back, so this one lands under `outer`.
    const third = try world.entity(.{ .name = "third" });
    s.end();

    try std.testing.expectEqual(outer, world.getParent(first));
    try std.testing.expectEqual(inner_parent, world.getParent(second));
    try std.testing.expectEqual(outer, world.getParent(third));
    try std.testing.expectEqual(@as(zecs.Entity, 0), zecs.c.entity.ecs_get_scope(world.raw));

    // With the scope closed, a bare name is a root name again.
    const root_level = try world.entity(.{ .name = "root_level" });
    try std.testing.expectEqual(@as(zecs.Entity, 0), world.getParent(root_level));
}

test "an entity reports what it is made of" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    const bare = world.newEntity();
    try std.testing.expectEqual(@as(usize, 0), world.typeOf(bare).len);
    try std.testing.expect(world.typeStr(bare) == null);

    const e = world.newEntity();
    world.set(e, position, .{ .x = 0, .y = 0 });
    world.set(e, velocity, .{ .x = 0, .y = 0 });

    const ids = world.typeOf(e);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expect(std.mem.indexOfScalar(zecs.Id, ids, position.asId()) != null);
    try std.testing.expect(std.mem.indexOfScalar(zecs.Id, ids, velocity.asId()) != null);

    const named = try world.entity(.{ .name = "thing" });
    {
        const s = world.idStr(named).?;
        defer s.deinit();
        try std.testing.expectEqualStrings("thing", s.value);
    }

    const target = try world.entity(.{ .name = "target" });
    {
        const s = world.idStr(zecs.pair(named, target)).?;
        defer s.deinit();
        try std.testing.expectEqualStrings("(thing,target)", s.value);
    }

    // Tags with names of their own, so the rendering is checkable without depending on
    // what `@typeName` produces for a component.
    const tagged = world.newEntity();
    world.addId(tagged, named);
    world.addPair(tagged, named, target);
    {
        const s = world.typeStr(tagged).?;
        defer s.deinit();
        try std.testing.expectEqualStrings("thing, (thing,target)", s.value);
    }
}

test "children are walked, in the parent's own order" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const parent = try world.entity(.{ .name = "parent" });
    var expected: [3]zecs.Entity = undefined;
    for (&expected, 0..) |*slot, i| {
        slot.* = try world.entity(.{
            .name = switch (i) {
                0 => "a",
                1 => "b",
                else => "c",
            },
            .parent = parent,
        });
    }

    var seen: usize = 0;
    var it = world.children(parent);
    defer it.deinit();
    while (it.next()) |row| {
        for (row.entities()) |child| {
            try std.testing.expect(std.mem.indexOfScalar(zecs.Entity, &expected, child) != null);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);

    // A childless entity yields nothing rather than failing.
    var empty = world.children(expected[0]);
    defer empty.deinit();
    try std.testing.expect(empty.next() == null);
}

test "a typed pair stores the value of whichever element carries the type" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const damage = try world.component(Damage, .{});
    const fire = try world.entity(.{ .name = "fire" });
    const applies = try world.entity(.{ .name = "applies" });

    const e = world.newEntity();

    // First element is a component with data, so the pair holds a Damage.
    world.set(e, zecs.pairOf(damage, fire), .{ .amount = 3 });
    try std.testing.expectEqual(@as(i32, 3), world.get(e, zecs.pairOf(damage, fire)).?.amount);
    try std.testing.expectEqual(
        damage.asId(),
        zecs.c.entity.ecs_get_typeid(world.raw, zecs.pairOf(damage, fire).asId()),
    );

    // First element is a plain entity, so the second one carries the type.
    world.set(e, zecs.pairOf(applies, damage), .{ .amount = 5 });
    try std.testing.expectEqual(@as(i32, 5), world.get(e, zecs.pairOf(applies, damage)).?.amount);
    try std.testing.expectEqual(
        damage.asId(),
        zecs.c.entity.ecs_get_typeid(world.raw, zecs.pairOf(applies, damage).asId()),
    );

    // Neither element has data, so the pair is a tag and flecs agrees.
    const tag_pair = zecs.pairOf(applies, fire);
    try std.testing.expect(@TypeOf(tag_pair).isTag());
    world.add(e, tag_pair);
    try std.testing.expect(world.has(e, tag_pair));
    try std.testing.expectEqual(
        @as(zecs.Entity, 0),
        zecs.c.entity.ecs_get_typeid(world.raw, tag_pair.asId()),
    );

    // The two spellings of a pair id agree.
    try std.testing.expectEqual(zecs.pair(damage.asId(), fire), zecs.pairOf(damage, fire).asId());
}

//-----------------------------------------------------------------------------
// Derived component lifecycle hooks
//-----------------------------------------------------------------------------

var owned_live: i32 = 0;

/// A component that owns something. The counter stands in for the allocation.
const Owned = struct {
    tag: u32 = 0,
    alive: bool = false,

    fn make(tag: u32) Owned {
        owned_live += 1;
        return .{ .tag = tag, .alive = true };
    }

    pub fn deinit(self: *Owned) void {
        if (!self.alive) return;
        self.alive = false;
        owned_live -= 1;
    }
};

/// Plain data: nothing to derive, and the derivation should say so.
const Plain = struct { x: f32 };

test "a type with nothing to clean up derives no hooks at all" {
    const hooks = zecs.typeHooks(Plain);
    try std.testing.expect(hooks.ctor == null);
    try std.testing.expect(hooks.dtor == null);
    try std.testing.expect(hooks.copy == null);
    try std.testing.expect(hooks.move == null);

    // A tag has no storage for a hook to act on, and flecs refuses hooks on one.
    try std.testing.expect(zecs.typeHooks(Player).dtor == null);
}

test "a component with a deinit is destroyed, relocated and replaced correctly" {
    try zecs.setAllocator(std.testing.allocator);
    owned_live = 0;

    const world = try zecs.World.init();
    defer world.deinit();

    const owned = try world.component(Owned, .{ .hooks = zecs.typeHooks(Owned) });
    const player = try world.component(Player, .{});

    const e = world.newEntity();
    world.set(e, owned, Owned.make(1));
    try std.testing.expectEqual(@as(i32, 1), owned_live);
    try std.testing.expectEqual(@as(u32, 1), world.get(e, owned).?.tag);

    // Setting over a live value destroys what was there instead of leaking it.
    world.set(e, owned, Owned.make(2));
    try std.testing.expectEqual(@as(i32, 1), owned_live);
    try std.testing.expectEqual(@as(u32, 2), world.get(e, owned).?.tag);

    // Adding a second component moves the entity to another table. A Zig value
    // relocates by memcpy, so nothing is destroyed and nothing is duplicated.
    world.add(e, player);
    try std.testing.expectEqual(@as(i32, 1), owned_live);
    try std.testing.expectEqual(@as(u32, 2), world.get(e, owned).?.tag);

    // A second entity in the same table, deleted, makes flecs relocate the first one
    // into the hole it left.
    const other = world.newEntity();
    world.set(other, owned, Owned.make(3));
    world.add(other, player);
    try std.testing.expectEqual(@as(i32, 2), owned_live);
    world.delete(other);
    try std.testing.expectEqual(@as(i32, 1), owned_live);
    try std.testing.expectEqual(@as(u32, 2), world.get(e, owned).?.tag);

    world.remove(e, owned);
    try std.testing.expectEqual(@as(i32, 0), owned_live);
}

test "a component with a deinit is destroyed when its entity or its world goes" {
    try zecs.setAllocator(std.testing.allocator);
    owned_live = 0;

    {
        const world = try zecs.World.init();
        defer world.deinit();

        const owned = try world.component(Owned, .{ .hooks = zecs.typeHooks(Owned) });
        const e = world.newEntity();
        world.set(e, owned, Owned.make(1));
        world.delete(e);
        try std.testing.expectEqual(@as(i32, 0), owned_live);
    }

    {
        const world = try zecs.World.init();
        const owned = try world.component(Owned, .{ .hooks = zecs.typeHooks(Owned) });
        for (0..8) |i| {
            const e = world.newEntity();
            world.set(e, owned, Owned.make(@intCast(i)));
        }
        try std.testing.expectEqual(@as(i32, 8), owned_live);
        world.deinit();
        try std.testing.expectEqual(@as(i32, 0), owned_live);
    }
}

test "hooks can be installed after registration, and flecs constructs with them" {
    try zecs.setAllocator(std.testing.allocator);
    owned_live = 0;

    const world = try zecs.World.init();
    defer world.deinit();

    // Registration derives the hooks, so `setHooks` here is the second install rather
    // than the first: what it proves is that installing over an existing set is accepted
    // and leaves flecs constructing with them, which is the case a caller hits when the
    // type gained a `deinit` after the component was registered somewhere else.
    const owned = try world.component(Owned, .{ .hooks = .{} });
    world.setHooks(owned);

    // `ensure` adds the component without a value, so flecs constructs it. The derived
    // constructor writes `Owned{}`, which is not alive and so is not counted.
    const e = world.newEntity();
    const fresh = world.ensure(e, owned);
    try std.testing.expectEqual(@as(u32, 0), fresh.tag);
    try std.testing.expect(!fresh.alive);
    try std.testing.expectEqual(@as(i32, 0), owned_live);

    fresh.* = Owned.make(9);
    try std.testing.expectEqual(@as(i32, 1), owned_live);
    world.delete(e);
    try std.testing.expectEqual(@as(i32, 0), owned_live);
}

//-----------------------------------------------------------------------------
// Duplication: prefabs, instances and clone
//-----------------------------------------------------------------------------

var copied_live: i32 = 0;

/// A component that owns something AND says how to copy it. `copied_live` stands in for
/// the allocation, so a value that is duplicated raises it and a value that is handed
/// over does not.
const Copied = struct {
    tag: u32 = 0,
    alive: bool = false,

    fn make(tag: u32) Copied {
        copied_live += 1;
        return .{ .tag = tag, .alive = true };
    }

    pub fn dupe(self: Copied) Copied {
        if (!self.alive) return .{ .tag = self.tag, .alive = false };
        copied_live += 1;
        return .{ .tag = self.tag, .alive = true };
    }

    pub fn deinit(self: *Copied) void {
        if (!self.alive) return;
        self.alive = false;
        copied_live -= 1;
    }
};

test "registering a component installs the hooks its type needs, without being asked" {
    try zecs.setAllocator(std.testing.allocator);
    owned_live = 0;

    const world = try zecs.World.init();
    defer world.deinit();

    // `.{}` used to mean "no hooks", so an owning component registered the obvious way
    // leaked every value ever put in it and nothing said so. It now means "the ones the
    // type needs".
    const owned = try world.component(Owned, .{});

    const e = world.newEntity();
    world.set(e, owned, Owned.make(1));
    try std.testing.expectEqual(@as(i32, 1), owned_live);
    world.delete(e);
    try std.testing.expectEqual(@as(i32, 0), owned_live);

    // And a caller who wants none says so.
    const bare = try world.component(Plain, .{ .hooks = .{} });
    _ = bare;
}

test "a type that cannot be copied is marked, and the operations that would copy it refuse" {
    try zecs.setAllocator(std.testing.allocator);
    owned_live = 0;

    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const owned = try world.component(Owned, .{});

    try std.testing.expect(zecs.duplicable(Position));
    try std.testing.expect(!zecs.duplicable(Owned));

    const plain_source = world.newEntity();
    world.set(plain_source, position, .{ .x = 3, .y = 4 });

    // Plain data clones, and the copy is independent.
    const copy = try world.clone(0, plain_source, true);
    try std.testing.expectEqual(@as(f32, 3), world.get(copy, position).?.x);
    world.getMut(copy, position).?.x = 9;
    try std.testing.expectEqual(@as(f32, 3), world.get(plain_source, position).?.x);
    try std.testing.expectEqual(@as(zecs.Entity, 0), world.notDuplicable(plain_source));

    // An owning component with no `dupe` does not, and the refusal names it.
    const owning_source = world.newEntity();
    world.set(owning_source, owned, Owned.make(1));
    try std.testing.expectEqual(owned.asId(), world.notDuplicable(owning_source));
    try std.testing.expectError(
        zecs.Error.ComponentNotDuplicable,
        world.clone(0, owning_source, true),
    );

    // Cloning the SHAPE without the values is still fine: nothing is copied.
    const shape = try world.clone(0, owning_source, false);
    try std.testing.expect(world.has(shape, owned));
    try std.testing.expectEqual(@as(i32, 1), owned_live);
}

test "a type that says how to copy itself clones into an independent value" {
    try zecs.setAllocator(std.testing.allocator);
    copied_live = 0;

    {
        const world = try zecs.World.init();
        defer world.deinit();

        const copied = try world.component(Copied, .{});
        try std.testing.expect(zecs.duplicable(Copied));

        const source = world.newEntity();
        world.set(source, copied, Copied.make(1));
        // `set` copied: the caller's temporary and the world's value are two.
        try std.testing.expectEqual(@as(i32, 2), copied_live);

        const copy = try world.clone(0, source, true);
        try std.testing.expectEqual(@as(u32, 1), world.get(copy, copied).?.tag);
        try std.testing.expectEqual(@as(i32, 3), copied_live);

        world.delete(copy);
        try std.testing.expectEqual(@as(i32, 2), copied_live);
    }

    // The world took its own value with it; the caller's temporary was never the
    // world's to free, which is what "lives by value" means.
    try std.testing.expectEqual(@as(i32, 1), copied_live);
    copied_live = 0;
}

test "an instance of a prefab gets its own copy of the prefab's components" {
    try zecs.setAllocator(std.testing.allocator);

    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const health = try world.component(Health, .{});

    const base = try world.prefab("Enemy");
    world.set(base, position, .{ .x = 1, .y = 2 });
    world.set(base, health, .{ .value = 100 });

    // A prefab is left out of queries, which is the point of it.
    const q = try world.queryOf(.{position}, .{});
    defer q.deinit();
    try std.testing.expectEqual(@as(i32, 0), q.query.count().entities);

    const instance = world.newEntity();
    try world.isA(instance, base);

    // Override is flecs's default, so the instance owns its own value.
    try std.testing.expect(world.owns(instance, position));
    try std.testing.expectEqual(@as(f32, 1), world.get(instance, position).?.x);
    world.getMut(instance, position).?.x = 50;
    try std.testing.expectEqual(@as(f32, 1), world.get(base, position).?.x);

    // And the instance is an ordinary entity as far as queries are concerned.
    try std.testing.expectEqual(@as(i32, 1), q.query.count().entities);
    try std.testing.expectEqual(@as(i32, 100), world.get(instance, health).?.value);
}

test "a component marked to inherit is shared by the instances rather than copied" {
    try zecs.setAllocator(std.testing.allocator);

    const world = try zecs.World.init();
    defer world.deinit();

    const health = try world.component(Health, .{});
    try world.inheritOnInstantiate(health);

    const base = try world.prefab("Shared");
    world.set(base, health, .{ .value = 42 });

    const a = world.newEntity();
    const b = world.newEntity();
    try world.isA(a, base);
    try world.isA(b, base);

    // Both read the base's value, and neither has one of its own.
    try std.testing.expect(!world.owns(a, health));
    try std.testing.expect(world.has(a, health));
    try std.testing.expectEqual(@as(i32, 42), world.get(a, health).?.value);

    world.getMut(base, health).?.value = 7;
    try std.testing.expectEqual(@as(i32, 7), world.get(a, health).?.value);
    try std.testing.expectEqual(@as(i32, 7), world.get(b, health).?.value);
}

test "instantiating a prefab that carries an uncopyable component is refused" {
    try zecs.setAllocator(std.testing.allocator);
    owned_live = 0;

    const world = try zecs.World.init();
    defer world.deinit();

    const owned = try world.component(Owned, .{});

    // Marked before it is used anywhere: instances never receive a copy of this one, so
    // it is not a hazard even though its type cannot be duplicated.
    const hidden = try world.component(HiddenOwned, .{});
    try world.dontInheritOnInstantiate(hidden);

    const base = try world.prefab("Owner");
    world.set(base, owned, Owned.make(1));
    world.set(base, hidden, .{ .live = &hidden_live });
    hidden_live = 1;
    try std.testing.expectEqual(@as(i32, 1), owned_live);

    const instance = world.newEntity();
    try std.testing.expectError(zecs.Error.ComponentNotDuplicable, world.isA(instance, base));
    try std.testing.expect(!world.has(instance, owned));
    // One value, still the prefab's.
    try std.testing.expectEqual(@as(i32, 1), owned_live);

    // Without the component flecs would have copied, the instance is allowed — and it
    // simply does not get the one that is marked away.
    world.remove(base, owned);
    try std.testing.expectEqual(@as(i32, 0), owned_live);
    try world.isA(instance, base);
    try std.testing.expect(!world.has(instance, hidden));
    try std.testing.expectEqual(@as(i32, 1), hidden_live);

    // And the trait cannot be changed once the component is in use: flecs aborts on
    // that, so the package refuses first.
    try std.testing.expectError(zecs.Error.ComponentInUse, world.overrideOnInstantiate(hidden));
}

var hidden_live: i32 = 0;

/// Owns something, like `Owned`, but kept off instances by its trait rather than by the
/// refusal — the other half of the same rule.
const HiddenOwned = struct {
    live: ?*i32 = null,

    pub fn deinit(self: *HiddenOwned) void {
        if (self.live) |counter| counter.* -= 1;
        self.live = null;
    }
};

test "a flecs string is freed through flecs's own allocator" {
    var counting = Counting{ .backing = std.testing.allocator };
    try zecs.setAllocator(counting.allocator());

    const world = try zecs.World.init();

    const root = try world.entity(.{ .name = "root" });
    const leaf = try world.entity(.{ .name = "leaf", .parent = root });

    // One round trip first, so anything flecs allocates lazily on the way is already
    // allocated and the measurement below is of the string alone.
    world.pathOf(leaf, .{}).?.deinit();

    const before = counting.live_blocks.load(.monotonic);
    const p = world.pathOf(leaf, .{}).?;
    try std.testing.expect(counting.live_blocks.load(.monotonic) > before);
    p.deinit();
    try std.testing.expectEqual(before, counting.live_blocks.load(.monotonic));

    world.deinit();
    try std.testing.expectEqual(@as(isize, 0), counting.live_blocks.load(.monotonic));

    try zecs.setAllocator(std.testing.allocator);
}

test "exclusive access is claimed and released in pairs" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const e = world.newEntity();

    {
        var access = world.exclusiveAccess("behaviour test");
        defer access.end();
        world.set(e, position, .{ .x = 1, .y = 0 });
    }
    try std.testing.expectEqual(@as(f32, 1), world.get(e, position).?.x);

    // Ending with the world locked leaves it readable and unwritable by anyone; the
    // way back is another scope, ended normally.
    var access = world.exclusiveAccess("behaviour test");
    access.endLocked();
    access.endLocked();
    try std.testing.expectEqual(@as(f32, 1), world.get(e, position).?.x);

    var unlock = world.exclusiveAccess("behaviour test");
    unlock.end();
    world.set(e, position, .{ .x = 2, .y = 0 });
    try std.testing.expectEqual(@as(f32, 2), world.get(e, position).?.x);
}

//=============================================================================
// String building, JSON and doc
//
// JSON is written from reflection data, so the components here register their members
// with flecs's meta addon and are `extern struct` for the same reason: the offsets
// flecs computes are C's, and a Zig struct is only guaranteed to agree with them when
// it is declared to.
//=============================================================================

const Point = extern struct { x: f32, y: f32 };
const Level = extern struct { value: i32 };

/// Registers `T`'s members so flecs can serialize a value of it. `members` is the
/// `{ name, type }` list flecs's `ecs_struct` macro takes.
fn describeStruct(
    world: zecs.World,
    comp: anytype,
    members: []const zecs.c.core.ecs_member_t,
) !void {
    var desc: zecs.c.meta.ecs_struct_desc_t = .{ .entity = comp.asId() };
    @memcpy(desc.members[0..members.len], members);
    if (zecs.c.meta.ecs_struct_init(world.raw, &desc) == 0) return error.StructInitFailed;
}

fn f32Id() zecs.Entity {
    return zecs.c.core.FLECS_IDecs_f32_tID_;
}

fn i32Id() zecs.Entity {
    return zecs.c.core.FLECS_IDecs_i32_tID_;
}

test "a component value serialises to JSON with its member names and values" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const point = try world.component(Point, .{ .name = "Point" });
    try describeStruct(world, point, &.{
        .{ .name = "x", .type = f32Id() },
        .{ .name = "y", .type = f32Id() },
    });

    const value: Point = .{ .x = 1.5, .y = -2.5 };
    const json = try zecs.json.valueToJson(world, point, &value);
    defer json.deinit();

    try std.testing.expectEqualStrings("{\"x\":1.5, \"y\":-2.5}", json.bytes);

    // The sentinel is carried, so the same bytes can go straight back to a C API.
    try std.testing.expectEqual(@as(u8, 0), json.bytes[json.bytes.len]);

    const array = try zecs.json.arrayToJson(world, point, &.{ value, .{ .x = 0, .y = 0 } });
    defer array.deinit();
    try std.testing.expectEqualStrings("[{\"x\":1.5, \"y\":-2.5}, {\"x\":0, \"y\":0}]", array.bytes);
}

test "an entity serialises to JSON with the components it has" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const point = try world.component(Point, .{ .name = "Point" });
    try describeStruct(world, point, &.{
        .{ .name = "x", .type = f32Id() },
        .{ .name = "y", .type = f32Id() },
    });

    const e = try world.entity(.{ .name = "marker" });
    world.set(e, point, .{ .x = 3, .y = 4 });

    const json = try zecs.json.entityToJson(world, e, .{ .serialize_values = true });
    defer json.deinit();

    try std.testing.expect(std.mem.indexOf(u8, json.bytes, "marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.bytes, "Point") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.bytes, "\"x\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.bytes, "\"y\":4") != null);

    // A zeroed descriptor is not flecs's default: the macro a C caller would have used
    // turns values on, and `.{}` here does not.
    const ids_only = try zecs.json.entityToJson(world, e, .{});
    defer ids_only.deinit();
    try std.testing.expect(std.mem.indexOf(u8, ids_only.bytes, "\"x\":3") == null);

    const as_c_would = try zecs.json.entityToJson(world, e, zecs.json.entity_defaults);
    defer as_c_would.deinit();
    try std.testing.expect(std.mem.indexOf(u8, as_c_would.bytes, "\"x\":3") != null);
}

test "type info serialises the structure rather than a value" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const point = try world.component(Point, .{ .name = "Point" });
    try describeStruct(world, point, &.{
        .{ .name = "x", .type = f32Id() },
        .{ .name = "y", .type = f32Id() },
    });

    const json = try zecs.json.typeInfoToJson(world, point.asId());
    defer json.deinit();

    try std.testing.expect(std.mem.indexOf(u8, json.bytes, "\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.bytes, "\"y\"") != null);
    // The member types come back as flecs's own primitive names, not Zig's.
    try std.testing.expectEqualStrings("{\"x\":[\"float\"], \"y\":[\"float\"]}", json.bytes);
}

test "a JSON string parses back into the component value it named" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const point = try world.component(Point, .{ .name = "Point" });
    try describeStruct(world, point, &.{
        .{ .name = "x", .type = f32Id() },
        .{ .name = "y", .type = f32Id() },
    });

    var value: Point = .{ .x = 0, .y = 0 };
    const rest = try zecs.json.valueFromJson(world, point, &value, "{\"x\":7, \"y\":-8} tail", .{});

    try std.testing.expectEqual(@as(f32, 7), value.x);
    try std.testing.expectEqual(@as(f32, -8), value.y);

    // The parser stops where the value ends, and what is left is the tail of the very
    // slice that went in rather than a bare pointer into it.
    try std.testing.expectEqualStrings(" tail", rest);

    var junk: Point = .{ .x = 1, .y = 1 };
    try std.testing.expectError(
        zecs.Error.JsonParseFailed,
        zecs.json.valueFromJson(world, point, &junk, "{\"x\":", .{}),
    );
}

test "an entity is rebuilt from the JSON another entity produced" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const point = try world.component(Point, .{ .name = "Point" });
    try describeStruct(world, point, &.{
        .{ .name = "x", .type = f32Id() },
        .{ .name = "y", .type = f32Id() },
    });

    const source = world.newEntity();
    world.set(source, point, .{ .x = 11, .y = 12 });

    const json = try zecs.json.entityToJson(world, source, .{ .serialize_values = true });
    defer json.deinit();

    const target = world.newEntity();
    _ = try zecs.json.entityFromJson(world, target, json.bytes, .{});

    const read = world.get(target, point).?;
    try std.testing.expectEqual(@as(f32, 11), read.x);
    try std.testing.expectEqual(@as(f32, 12), read.y);
}

test "an iterator serialises to JSON containing every entity it matched" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const point = try world.component(Point, .{ .name = "Point" });
    try describeStruct(world, point, &.{
        .{ .name = "x", .type = f32Id() },
        .{ .name = "y", .type = f32Id() },
    });

    const names = [_][:0]const u8{ "alpha", "beta", "gamma" };
    for (names, 0..) |name, i| {
        const e = try world.entity(.{ .name = name });
        world.set(e, point, .{ .x = @floatFromInt(i), .y = 0 });
    }

    const query = try world.query(.{ .terms = &.{.{ .id = point.asId() }} });
    defer query.deinit();

    var it = query.iter();
    // Serializing runs the iteration to its end and flecs releases it there. The
    // wrapper records that, so this stays correct rather than becoming a double free.
    defer it.deinit();

    // `iter_defaults` rather than `.{}`: a zeroed descriptor leaves `serialize_fields`
    // off, and without it the results are entity names with no values attached.
    const json = try zecs.json.iterToJson(&it, zecs.json.iter_defaults);
    defer json.deinit();

    for (names) |name| {
        try std.testing.expect(std.mem.indexOf(u8, json.bytes, name) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, json.bytes, "\"x\":2") != null);

    // An iteration built through the raw layer serializes the same way. There is
    // nothing to defuse in that case: the caller owns the `ecs_iter_t` outright and
    // flecs has released its contents by the time this returns.
    var raw_it = zecs.c.query.ecs_query_iter(world.raw, query.raw);
    const from_raw = try zecs.json.iterToJson(&raw_it, zecs.json.iter_defaults);
    defer from_raw.deinit();
    try std.testing.expectEqualStrings(json.bytes, from_raw.bytes);
}

test "the writer adapter produces exactly the bytes the owned string holds" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const point = try world.component(Point, .{ .name = "Point" });
    const level = try world.component(Level, .{ .name = "Level" });
    try describeStruct(world, point, &.{
        .{ .name = "x", .type = f32Id() },
        .{ .name = "y", .type = f32Id() },
    });
    try describeStruct(world, level, &.{.{ .name = "value", .type = i32Id() }});

    const e = try world.entity(.{ .name = "both" });
    world.set(e, point, .{ .x = 1, .y = 2 });
    world.set(e, level, .{ .value = 9 });

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    // A local rather than a helper, because each pair needs its own arguments and the
    // point of the test is that both halves of every pair see the same ones.
    const check = struct {
        fn eq(owned: zecs.strbuf.Owned, written: []const u8) !void {
            defer owned.deinit();
            try std.testing.expect(owned.bytes.len != 0);
            try std.testing.expectEqualStrings(owned.bytes, written);
        }
    }.eq;

    const value: Point = .{ .x = 1, .y = 2 };
    try zecs.json.writeValue(&sink.writer, world, point, &value);
    try check(try zecs.json.valueToJson(world, point, &value), sink.written());

    const values = [_]Point{ value, .{ .x = 3, .y = 4 } };
    sink.clearRetainingCapacity();
    try zecs.json.writeArray(&sink.writer, world, point, &values);
    try check(try zecs.json.arrayToJson(world, point, &values), sink.written());

    sink.clearRetainingCapacity();
    try zecs.json.writeTypeInfo(&sink.writer, world, point.asId());
    try check(try zecs.json.typeInfoToJson(world, point.asId()), sink.written());

    const entity_desc: zecs.c.json.ecs_entity_to_json_desc_t = .{
        .serialize_values = true,
        .serialize_type_info = true,
        .serialize_full_paths = true,
    };
    sink.clearRetainingCapacity();
    try zecs.json.writeEntity(&sink.writer, world, e, entity_desc);
    try check(try zecs.json.entityToJson(world, e, entity_desc), sink.written());

    // Each serialization consumes an iterator, so the two halves need one each.
    const query = try world.query(.{ .terms = &.{.{ .id = point.asId() }} });
    defer query.deinit();

    var written_it = query.iter();
    defer written_it.deinit();
    sink.clearRetainingCapacity();
    try zecs.json.writeIter(&sink.writer, &written_it, zecs.json.iter_defaults);

    var owned_it = query.iter();
    defer owned_it.deinit();
    try check(try zecs.json.iterToJson(&owned_it, zecs.json.iter_defaults), sink.written());

    // And the same has to hold for a document long enough to outgrow the buffer's
    // inline storage, which is where the two paths could start to differ.
    for (0..400) |i| {
        const child = try world.entity(.{ .name = "child", .parent = e });
        world.set(child, level, .{ .value = @intCast(i) });
    }

    sink.clearRetainingCapacity();
    try zecs.json.writeWorld(&sink.writer, world, .{});
    try std.testing.expect(sink.written().len > 512);
    try check(try zecs.json.worldToJson(world, .{}), sink.written());
}

test "a world round-trips through JSON into a second world" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);

    const scene = blk: {
        const world = try zecs.World.init();
        defer world.deinit();

        const point = try world.component(Point, .{ .name = "Point" });
        try describeStruct(world, point, &.{
            .{ .name = "x", .type = f32Id() },
            .{ .name = "y", .type = f32Id() },
        });

        const e = try world.entity(.{ .name = "saved" });
        world.set(e, point, .{ .x = 5, .y = 6 });

        break :blk try zecs.json.worldToJson(world, .{});
    };
    defer scene.deinit();

    const restored = try zecs.World.init();
    defer restored.deinit();

    const point = try restored.component(Point, .{ .name = "Point" });
    try describeStruct(restored, point, &.{
        .{ .name = "x", .type = f32Id() },
        .{ .name = "y", .type = f32Id() },
    });

    _ = try zecs.json.worldFromJson(restored, scene.bytes, .{});

    const e = restored.lookup("saved");
    try std.testing.expect(e != 0);
    const read = restored.get(e, point).?;
    try std.testing.expectEqual(@as(f32, 5), read.x);
    try std.testing.expectEqual(@as(f32, 6), read.y);
}

test "a world loads from a JSON file, and a missing file is an error" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);

    // flecs opens the path with `fopen`, so a relative one resolves against the
    // process's working directory — the same one this writes into.
    const cwd = std.Io.Dir.cwd();
    const file_name = "zecs-json-scene.test.json";

    {
        const world = try zecs.World.init();
        defer world.deinit();

        const level = try world.component(Level, .{ .name = "Level" });
        try describeStruct(world, level, &.{.{ .name = "value", .type = i32Id() }});

        const e = try world.entity(.{ .name = "stored" });
        world.set(e, level, .{ .value = 31 });

        const scene = try zecs.json.worldToJson(world, .{});
        defer scene.deinit();
        try cwd.writeFile(std.testing.io, .{ .sub_path = file_name, .data = scene.bytes });
    }
    defer cwd.deleteFile(std.testing.io, file_name) catch {};

    const world = try zecs.World.init();
    defer world.deinit();

    const level = try world.component(Level, .{ .name = "Level" });
    try describeStruct(world, level, &.{.{ .name = "value", .type = i32Id() }});

    try zecs.json.worldFromJsonFile(world, file_name, .{});

    const e = world.lookup("stored");
    try std.testing.expect(e != 0);
    try std.testing.expectEqual(@as(i32, 31), world.get(e, level).?.value);

    try std.testing.expectError(
        zecs.Error.JsonParseFailed,
        zecs.json.worldFromJsonFile(world, "no-such-scene.json", .{}),
    );
}

test "the strbuf writer builds a string flecs then consumes" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    var builder: zecs.strbuf.Builder = .init(&.{});
    defer builder.deinit();

    try builder.interface.print("entity_{d}", .{7});

    const name = builder.toOwned().?;
    defer name.deinit();
    try std.testing.expectEqualStrings("entity_7", name.bytes);

    const e = try world.entity(.{ .name = name.bytes });
    try std.testing.expectEqual(e, world.lookup("entity_7"));

    // The builder is empty and reusable once its contents have been taken.
    try std.testing.expect(builder.toOwned() == null);
}

test "flecs appends into the same buffer a Zig writer is filling" {
    if (comptime !zecs.options.addon_json) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const point = try world.component(Point, .{ .name = "Point" });
    try describeStruct(world, point, &.{
        .{ .name = "x", .type = f32Id() },
        .{ .name = "y", .type = f32Id() },
    });

    const e = try world.entity(.{ .name = "wrapped" });
    world.set(e, point, .{ .x = 1, .y = 2 });

    var builder: zecs.strbuf.Builder = .init(&.{});
    defer builder.deinit();

    try builder.interface.writeAll("{\"payload\": ");
    const rc = zecs.c.json.ecs_entity_to_json_buf(
        world.raw,
        e,
        builder.strbuf(),
        &.{ .serialize_values = true },
    );
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try builder.interface.writeAll("}");

    const document = builder.toOwned().?;
    defer document.deinit();

    try std.testing.expect(std.mem.startsWith(u8, document.bytes, "{\"payload\": {"));
    try std.testing.expect(std.mem.endsWith(u8, document.bytes, "}}"));
    try std.testing.expect(std.mem.indexOf(u8, document.bytes, "wrapped") != null);
}

test "documentation strings are copied in, borrowed out, and removable" {
    if (comptime !zecs.options.addon_doc) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const e = try world.entity(.{ .name = "thing" });

    zecs.doc.set(world, e, .brief, "One line about it");
    zecs.doc.set(world, e, .detail, "Several lines about it");
    zecs.doc.set(world, e, .color, "#336699");
    zecs.doc.set(world, e, .uuid, "6f1a-c3");

    try std.testing.expectEqualStrings("One line about it", zecs.doc.get(world, e, .brief).?);
    try std.testing.expectEqualStrings("Several lines about it", zecs.doc.get(world, e, .detail).?);
    try std.testing.expectEqualStrings("#336699", zecs.doc.get(world, e, .color).?);
    try std.testing.expectEqualStrings("6f1a-c3", zecs.doc.get(world, e, .uuid).?);
    try std.testing.expect(zecs.doc.get(world, e, .link) == null);

    // The string is copied on the way in, so the caller's buffer is free immediately.
    var scratch: [16:0]u8 = @splat(0);
    @memcpy(scratch[0..5], "hello");
    zecs.doc.set(world, e, .link, scratch[0..5 :0]);
    @memset(scratch[0..16], 'z');
    try std.testing.expectEqualStrings("hello", zecs.doc.get(world, e, .link).?);

    // Null removes.
    zecs.doc.set(world, e, .brief, null);
    try std.testing.expect(zecs.doc.get(world, e, .brief) == null);
}

test "the doc name falls back to the entity's own name" {
    if (comptime !zecs.options.addon_doc) return error.SkipZigTest;
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const named = try world.entity(.{ .name = "physics_step" });
    const anonymous = world.newEntity();

    // No doc name set, so flecs answers with the entity's name instead of null.
    try std.testing.expectEqualStrings("physics_step", zecs.doc.get(world, named, .name).?);
    try std.testing.expect(zecs.doc.get(world, anonymous, .name) == null);

    zecs.doc.set(world, named, .name, "Physics step");
    try std.testing.expectEqualStrings("Physics step", zecs.doc.get(world, named, .name).?);

    // Removing the doc name returns the fallback rather than null.
    zecs.doc.set(world, named, .name, null);
    try std.testing.expectEqualStrings("physics_step", zecs.doc.get(world, named, .name).?);
}

//=============================================================================
// Tables, direct storage, values and script
//
// The storage-facing half of the API. These tests care about one thing above all: that
// a slice taken out of a table's column is the same memory the ordinary `get` path
// reads, in the same order, and that writing through it is a write to the world.
//=============================================================================

/// Registers a component and describes its two `f32` members to flecs's reflection
/// layer, which is what a script needs before it can fill one in by member name.
fn registerReflected(
    world: zecs.World,
    comptime T: type,
    comptime name: [:0]const u8,
) !zecs.Component(T) {
    const comp = try world.component(T, .{ .name = name });
    var members: [32]zecs.c.core.ecs_member_t = @splat(.{});
    members[0] = .{ .name = "x", .type = zecs.c.core.FLECS_IDecs_f32_tID_ };
    members[1] = .{ .name = "y", .type = zecs.c.core.FLECS_IDecs_f32_tID_ };
    const desc: zecs.c.meta.ecs_struct_desc_t = .{ .entity = comp.asId(), .members = members };
    if (zecs.c.meta.ecs_struct_init(world.raw, &desc) == 0) return error.StructInitFailed;
    return comp;
}

test "a column slice holds what getting each entity in turn reads" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    // Two archetypes, so the query walks more than one table and the test proves the
    // per-table lengths rather than one global count.
    for (0..12) |i| {
        const e = world.newEntity();
        world.set(e, position, .{ .x = @floatFromInt(i), .y = 0 });
        if (i % 2 == 0) world.set(e, velocity, .{ .x = 1, .y = 0 });
    }

    const query = try world.query(.{ .terms = &.{.{ .id = position.asId() }} });
    defer query.deinit();

    var tables: usize = 0;
    var rows: usize = 0;
    var it = query.iter();
    defer it.deinit();
    while (it.next()) |row| {
        const table = zecs.Table.fromIter(row).?;
        tables += 1;

        const held = table.lock();
        defer held.unlock();

        const column = table.columnOf(position).?;
        const entities = table.entities();
        try std.testing.expectEqual(table.count(), column.len);
        try std.testing.expectEqual(column.len, entities.len);
        try std.testing.expect(table.capacity() >= table.count());

        for (entities, column) |e, p| {
            try std.testing.expectEqual(world.get(e, position).?.*, p);
            rows += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 2), tables);
    try std.testing.expectEqual(@as(usize, 12), rows);
}

test "writing through a column slice is a write to the world" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});

    var made: [8]zecs.Entity = undefined;
    for (&made, 0..) |*slot, i| {
        slot.* = world.newEntity();
        world.set(slot.*, position, .{ .x = @floatFromInt(i), .y = 0 });
    }

    const table = zecs.Table.of(world, made[0]).?;
    const index = table.columnIndex(position.asId()).?;
    {
        const held = table.lock();
        defer held.unlock();
        for (table.column(Position, index)) |*p| p.y = p.x * 2;
    }

    for (made, 0..) |e, i| {
        const p = world.get(e, position).?;
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), p.x);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i * 2)), p.y);
    }
}

test "a table's columns and type match what was added, and tags take no column" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});
    const player = try world.component(Player, .{}); // zero-sized: a tag

    const e = world.newEntity();
    world.set(e, position, .{ .x = 1, .y = 2 });
    world.set(e, velocity, .{ .x = 3, .y = 4 });
    world.add(e, player);

    const table = zecs.Table.of(world, e).?;
    try std.testing.expectEqual(@as(usize, 3), table.ids().len);
    try std.testing.expectEqual(@as(usize, 2), table.columnCount());
    try std.testing.expectEqual(@as(usize, 1), table.count());

    // A tag is in the type but has no storage.
    try std.testing.expect(table.typeIndex(player.asId()) != null);
    try std.testing.expect(table.columnIndex(player.asId()) == null);

    // The two index spaces convert back and forth, and the type index names the id.
    const column = table.columnIndex(velocity.asId()).?;
    const in_type = table.columnToTypeIndex(column).?;
    try std.testing.expectEqual(column, table.typeToColumnIndex(in_type).?);
    try std.testing.expectEqual(velocity.asId(), table.ids()[in_type]);
    try std.testing.expectEqual(@as(usize, @sizeOf(Velocity)), table.columnSize(column).?);

    // A table with no such component says so, rather than handing back an empty slice.
    const health = try world.component(Health, .{});
    try std.testing.expect(table.columnOf(health) == null);

    const text = table.str().?;
    defer zecs.freeString(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Velocity") != null);

    // Depth counts targets up an acyclic relationship. A table whose entities have no
    // parent is at zero, its children at one.
    const child = try world.entity(.{ .name = "child", .parent = e });
    world.set(child, position, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(usize, 0), table.depth(zecs.Builtin.child_of.id()).?);
    try std.testing.expectEqual(
        @as(usize, 1),
        zecs.Table.of(world, child).?.depth(zecs.Builtin.child_of.id()).?,
    );
}

test "an emptied table still has its columns, and reports them as empty" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});

    const e = world.newEntity();
    world.set(e, position, .{ .x = 1, .y = 2 });
    const table = zecs.Table.of(world, e).?;

    world.delete(e);

    // flecs keeps the table. `columnOf` has to distinguish "no such component" from
    // "no rows yet", which its C counterpart does not.
    try std.testing.expectEqual(@as(usize, 0), table.count());
    try std.testing.expectEqual(@as(usize, 0), table.columnOf(position).?.len);
    try std.testing.expectEqual(@as(usize, 0), table.entities().len);
}

test "adding a component moves the entity to the table the graph names" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    // An entity with no components is in the root table, not in no table.
    const e = world.newEntity();
    const root = zecs.Table.of(world, e).?;
    try std.testing.expectEqual(@as(usize, 0), root.ids().len);
    try std.testing.expectEqual(@as(usize, 0), root.columnCount());

    world.set(e, position, .{ .x = 1, .y = 2 });

    const before = zecs.Table.of(world, e).?;
    const predicted = before.addId(velocity.asId()).?;

    world.set(e, velocity, .{ .x = 3, .y = 4 });
    const after = zecs.Table.of(world, e).?;

    try std.testing.expect(before.raw != after.raw);
    try std.testing.expectEqual(predicted.raw, after.raw);
    try std.testing.expectEqual(before.raw, after.removeId(velocity.asId()).?.raw);
}

test "swapping two rows moves the entities and their components together" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});

    var made: [3]zecs.Entity = undefined;
    for (&made, 0..) |*slot, i| {
        slot.* = world.newEntity();
        world.set(slot.*, position, .{ .x = @floatFromInt(i), .y = 0 });
    }

    const table = zecs.Table.of(world, made[0]).?;

    var before: [3]zecs.Entity = undefined;
    @memcpy(&before, table.entities());

    table.swapRows(0, 2);

    // The slices were invalidated by the swap, so they are taken again.
    try std.testing.expectEqual(before[2], table.entities()[0]);
    try std.testing.expectEqual(before[0], table.entities()[2]);
    for (table.entities(), table.columnOf(position).?) |e, p| {
        try std.testing.expectEqual(world.get(e, position).?.*, p);
    }
}

test "a record reads one entity's element of a column" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});

    var made: [4]zecs.Entity = undefined;
    for (&made, 0..) |*slot, i| {
        slot.* = world.newEntity();
        world.set(slot.*, position, .{ .x = @floatFromInt(i), .y = 0 });
    }

    // The column index is the table's, so it is found once and reused for every entity
    // in it — which is the whole reason the by-column form exists.
    const table = zecs.Table.of(world, made[0]).?;
    const index = table.columnIndex(position.asId()).?;
    for (made, 0..) |e, i| {
        const record = zecs.Record.find(world, e).?;
        try std.testing.expectEqual(table.raw, record.table(world).?.raw);
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), record.column(Position, index).?.x);
    }

    // The record is where the column index came from, so the two agree about the row.
    const first = zecs.Record.find(world, made[0]).?;
    try std.testing.expectEqual(
        &table.column(Position, index)[0],
        first.column(Position, index).?,
    );
}

test "the direct-access guards hand back the entity's own storage" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const e = world.newEntity();
    world.set(e, position, .{ .x = 1, .y = 2 });

    const index = zecs.Table.of(world, e).?.columnIndex(position.asId()).?;

    {
        const held = try zecs.writeBegin(world, e);
        defer held.end();
        held.record().column(Position, index).?.x = 42;
    }
    try std.testing.expectEqual(@as(f32, 42), world.get(e, position).?.x);

    {
        const held = try zecs.readBegin(world, e);
        defer held.end();
        try std.testing.expectEqual(@as(f32, 42), held.record().column(Position, index).?.x);
    }
}

test "a ref follows its entity between tables and goes null when it dies" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});
    const health = try world.component(Health, .{});

    const e = world.newEntity();
    world.set(e, position, .{ .x = 3, .y = 4 });

    var handle = try zecs.ref(world, e, position);
    try std.testing.expectEqual(@as(f32, 3), handle.get(world).?.x);

    // Adding a component moves the entity to another table. A raw pointer from `get`
    // would dangle here; the ref revalidates itself.
    world.set(e, velocity, .{ .x = 1, .y = 1 });
    try std.testing.expectEqual(@as(f32, 3), handle.get(world).?.x);

    handle.get(world).?.x = 9;
    try std.testing.expectEqual(@as(f32, 9), world.get(e, position).?.x);

    // A ref for a component the entity does not have reads as absent rather than
    // pointing somewhere wrong.
    var absent = try zecs.ref(world, e, health);
    try std.testing.expect(absent.get(world) == null);

    world.delete(e);
    try std.testing.expect(handle.get(world) == null);
}

test "a value is constructed, copied, moved and freed through its component's type" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});

    // Storage flecs allocates and constructs.
    const owned = try zecs.Value.new(world, position);
    owned.* = .{ .x = 1, .y = 2 };

    // Storage the caller owns, constructed in place.
    var local: Position = undefined;
    try zecs.Value.init(world, position, &local);

    try zecs.Value.copy(world, position, &local, owned);
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, local);

    var moved: Position = undefined;
    try zecs.Value.moveCtor(world, position, &moved, &local);
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, moved);

    owned.* = .{ .x = 5, .y = 6 };
    try zecs.Value.move(world, position, &moved, owned);
    try std.testing.expectEqual(Position{ .x = 5, .y = 6 }, moved);

    try zecs.Value.fini(world, position, &moved);
    try zecs.Value.fini(world, position, &local);
    try zecs.Value.free(world, position, owned);
}

test "a script creates the entities and components it describes" {
    if (zecs.options.addon_script) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        const position = try registerReflected(world, Position, "Position");

        var diagnostic: zecs.Diagnostic = .{};
        defer diagnostic.deinit();

        try zecs.Script.run(world,
            \\sun {
            \\  Position: {x: 10, y: 20}
            \\  earth {
            \\    Position: {x: 30, y: 40}
            \\  }
            \\}
        , .{ .name = "solar", .diagnostic = &diagnostic });

        const sun = world.lookup("sun");
        try std.testing.expect(sun != 0);
        try std.testing.expectEqual(Position{ .x = 10, .y = 20 }, world.get(sun, position).?.*);

        const earth = world.lookupPath("sun.earth", .{});
        try std.testing.expect(earth != 0);
        try std.testing.expectEqual(sun, world.getParent(earth));
        try std.testing.expectEqual(Position{ .x = 30, .y = 40 }, world.get(earth, position).?.*);
    } else return error.SkipZigTest;
}

test "a script that does not parse returns an error rather than aborting" {
    if (zecs.options.addon_script) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        _ = try registerReflected(world, Position, "Position");

        var diagnostic: zecs.Diagnostic = .{};
        defer diagnostic.deinit();

        // Passing a diagnostic also keeps the message off flecs's log, which is what
        // makes a failed script a normal outcome rather than console noise.
        try std.testing.expectError(zecs.Error.ScriptRunFailed, zecs.Script.run(
            world,
            "sun { Position: {x: 10",
            .{ .name = "broken", .diagnostic = &diagnostic },
        ));
        try std.testing.expect(diagnostic.message != null);
        try std.testing.expect(world.lookup("sun") == 0);

        // And the same text refused at parse time, before anything is evaluated.
        var parse_diagnostic: zecs.Diagnostic = .{};
        defer parse_diagnostic.deinit();
        try std.testing.expectError(zecs.Error.ScriptParseFailed, zecs.Script.parse(
            world,
            "sun { Position: {x: 10",
            .{ .name = "broken", .diagnostic = &parse_diagnostic },
        ));
        try std.testing.expect(parse_diagnostic.message != null);
    } else return error.SkipZigTest;
}

test "a parsed script can be evaluated more than once" {
    if (zecs.options.addon_script) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        const position = try registerReflected(world, Position, "Position");

        const script = try zecs.Script.parse(world, "probe { Position: {x: 7, y: 8} }", .{});
        defer script.deinit();

        try script.eval(.{});
        const first = world.lookup("probe");
        try std.testing.expect(first != 0);
        try std.testing.expectEqual(Position{ .x = 7, .y = 8 }, world.get(first, position).?.*);

        world.delete(first);
        try std.testing.expect(world.lookup("probe") == 0);

        try script.eval(.{});
        const second = world.lookup("probe");
        try std.testing.expect(second != 0);
        try std.testing.expectEqual(Position{ .x = 7, .y = 8 }, world.get(second, position).?.*);

        const ast = script.astToString(false).?;
        defer zecs.freeString(ast);
        try std.testing.expect(std.mem.indexOf(u8, ast, "Position") != null);
    } else return error.SkipZigTest;
}

test "script variables carry typed values into a script and into a string" {
    if (zecs.options.addon_script) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        const position = try registerReflected(world, Position, "Position");
        const f32_type = zecs.Component(f32){ .id = zecs.c.core.FLECS_IDecs_f32_tID_ };
        const i32_type = zecs.Component(i32){ .id = zecs.c.core.FLECS_IDecs_i32_tID_ };

        var vars = try zecs.Vars.init(world);
        defer vars.deinit();

        try vars.set("width", f32_type, 12.5);
        try std.testing.expectEqual(@as(f32, 12.5), vars.get("width", f32_type).?.*);

        // A variable that is not there, and one that is there under another type.
        try std.testing.expect(vars.get("height", f32_type) == null);
        try std.testing.expect(vars.get("width", i32_type) == null);

        // The same name twice is refused rather than shadowed.
        try std.testing.expectError(zecs.Error.VariableDeclareFailed, vars.set("width", f32_type, 1));

        const script = try zecs.Script.parse(world, "post { Position: {x: $width, y: 0} }", .{});
        defer script.deinit();
        try script.eval(.{ .vars = vars });

        const post = world.lookup("post");
        try std.testing.expect(post != 0);
        try std.testing.expectEqual(@as(f32, 12.5), world.get(post, position).?.x);

        const text = vars.interpolate(world, "width is $width").?;
        defer zecs.freeString(text);
        try std.testing.expect(std.mem.startsWith(u8, text, "width is 12.5"));
    } else return error.SkipZigTest;
}

test "an expression evaluates to a Zig value of the type it was asked for" {
    if (zecs.options.addon_script) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        const i32_type = zecs.Component(i32){ .id = zecs.c.core.FLECS_IDecs_i32_tID_ };
        const f32_type = zecs.Component(f32){ .id = zecs.c.core.FLECS_IDecs_f32_tID_ };

        try std.testing.expectEqual(@as(i32, 30), try zecs.evalExpr(world, "10 + 20", i32_type));
        try std.testing.expectEqual(@as(f32, 2.5), try zecs.evalExpr(world, "5.0 / 2.0", f32_type));

        var expr = try zecs.Expr(i32).parse(world, "2 * 21", i32_type);
        defer expr.deinit();
        try std.testing.expectEqual(@as(i32, 42), try expr.eval());
        try std.testing.expectEqual(@as(i32, 42), try expr.eval());

        // A malformed expression is an error. flecs has no result parameter here, so
        // the log is captured by hand to keep the failure off the console.
        zecs.c.log.ecs_log_start_capture(true);
        const outcome = zecs.evalExpr(world, "10 +", i32_type);
        if (zecs.c.log.ecs_log_stop_capture()) |message| zecs.freeString(std.mem.span(message));
        try std.testing.expectError(zecs.Error.ExpressionFailed, outcome);
    } else return error.SkipZigTest;
}

test "a managed script deletes what a later version no longer describes" {
    if (zecs.options.addon_script) {
        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        const script = try zecs.Script.load(world, .{ .code = "alpha {}\nbeta {}" });
        try std.testing.expect(world.lookup("alpha") != 0);
        try std.testing.expect(world.lookup("beta") != 0);

        try zecs.Script.update(world, script, 0, "alpha {}");
        try std.testing.expect(world.lookup("alpha") != 0);
        try std.testing.expect(world.lookup("beta") == 0);
    } else return error.SkipZigTest;
}

test "a script runs from a file" {
    if (zecs.options.addon_script) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "scene.flecs",
            .data = "from_file {}\n",
        });

        // flecs opens the file itself, through its OS API, so it needs a path that is
        // good from the process's working directory rather than from this handle.
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, "scene.flecs", std.testing.allocator);
        defer std.testing.allocator.free(path);

        try zecs.setAllocator(std.testing.allocator);
        const world = try zecs.World.init();
        defer world.deinit();

        try zecs.Script.runFile(world, path);
        try std.testing.expect(world.lookup("from_file") != 0);
    } else return error.SkipZigTest;
}

//=============================================================================
// Scheduling, observability and the app loop
//
// The typed layer covers a small part of this area on purpose, so several of these
// tests drive `zecs.c` directly. That is not a workaround: a raw declaration is the
// binding for everything a wrapper would only rename, and these prove it works from
// Zig exactly as it does from C.
//=============================================================================

const Entity = zecs.Entity;

/// Appends one character per run, so a whole frame's ordering is a single string.
var phase_log: [16]u8 = undefined;
var phase_log_len: usize = 0;

fn phaseRecorder(comptime tag: u8) fn (*zecs.Iter) void {
    return struct {
        fn run(it: *zecs.Iter) void {
            _ = it;
            phase_log[phase_log_len] = tag;
            phase_log_len += 1;
        }
    }.run;
}

test "a system on a custom phase runs between the built-in phases it depends on" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const player = try world.component(Player, .{});
    const e = world.newEntity();
    world.add(e, player);

    const early = try zecs.pipeline.phase(world, .{
        .name = "Early",
        .after = zecs.Builtin.on_update.id(),
    });
    const late = try zecs.pipeline.phase(world, .{ .name = "Late", .after = early });

    // Registered back to front, so a pipeline that ordered systems by creation rather
    // than by phase depth would produce the reverse of what is expected.
    const terms: []const zecs.Term = &.{.{ .id = player.asId() }};
    _ = try world.system(.{
        .name = "PostFrameStep",
        .phase = zecs.Builtin.post_frame.id(),
        .query = .{ .terms = terms },
        .callback = zecs.callback(phaseRecorder('p')),
    });
    _ = try world.system(.{
        .name = "LateStep",
        .phase = late,
        .query = .{ .terms = terms },
        .callback = zecs.callback(phaseRecorder('l')),
    });
    _ = try world.system(.{
        .name = "EarlyStep",
        .phase = early,
        .query = .{ .terms = terms },
        .callback = zecs.callback(phaseRecorder('e')),
    });
    _ = try world.system(.{
        .name = "OnUpdateStep",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = terms },
        .callback = zecs.callback(phaseRecorder('u')),
    });

    phase_log_len = 0;
    _ = world.progress(1.0);
    try std.testing.expectEqualStrings("uelp", phase_log[0..phase_log_len]);

    // A phase is a phase because it carries the Phase tag and a DependsOn pair. Both,
    // or the pipeline query silently does not match the systems that depend on it.
    try std.testing.expect(world.hasId(early, zecs.Builtin.phase.id()));
    try std.testing.expectEqual(
        zecs.Builtin.on_update.id(),
        world.getTarget(early, zecs.Builtin.depends_on.id(), 0),
    );
}

test "a custom pipeline runs only the systems its query matches" {
    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const player = try world.component(Player, .{});
    const e = world.newEntity();
    world.add(e, player);

    const in_secondary = try world.entity(.{ .name = "InSecondary" });
    const terms: []const zecs.Term = &.{.{ .id = player.asId() }};

    const marked = try world.system(.{
        .name = "Marked",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = terms },
        .callback = zecs.callback(phaseRecorder('m')),
    });
    world.addId(marked, in_secondary);

    _ = try world.system(.{
        .name = "Unmarked",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = terms },
        .callback = zecs.callback(phaseRecorder('x')),
    });

    const secondary = try zecs.pipeline.create(world, .{
        .name = "Secondary",
        .query = .{ .terms = &.{
            .{ .id = zecs.c.core.EcsSystem },
            .{ .id = in_secondary },
            .{
                .id = zecs.c.core.EcsPhase,
                .src = .{ .id = zecs.Cascade },
                .trav = zecs.Builtin.depends_on.id(),
            },
        } },
    });

    zecs.c.pipeline.ecs_set_pipeline(world.raw, secondary);
    try std.testing.expectEqual(secondary, zecs.c.core.ecs_get_pipeline(world.raw));

    phase_log_len = 0;
    _ = world.progress(1.0);
    try std.testing.expectEqualStrings("m", phase_log[0..phase_log_len]);
}

var timer_ticks: u32 = 0;
var rate_ticks: u32 = 0;

fn countTimerTick(it: *zecs.Iter) void {
    _ = it;
    timer_ticks += 1;
}

fn countRateTick(it: *zecs.Iter) void {
    _ = it;
    rate_ticks += 1;
}

test "a timer ticks at its interval, and a rate filter divides it" {
    if (comptime !zecs.options.addon_timer) return error.SkipZigTest;

    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const player = try world.component(Player, .{});
    const e = world.newEntity();
    world.add(e, player);

    // A tick source is an entity. Passing zero asks flecs to make one; the entity it
    // returns is what a system is then pointed at.
    const timer = zecs.c.timer.ecs_set_interval(world.raw, 0, 0.5);
    try std.testing.expect(timer != 0);
    try std.testing.expectEqual(@as(zecs.c.core.ecs_ftime_t, 0.5), zecs.c.timer.ecs_get_interval(world.raw, timer));

    // A rate filter is a tick source too, counting the ticks of another one.
    const halved = zecs.c.timer.ecs_set_rate(world.raw, 0, 2, timer);

    const terms: []const zecs.Term = &.{.{ .id = player.asId() }};
    const fast = try world.system(.{
        .name = "Fast",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = terms },
        .callback = zecs.callback(countTimerTick),
    });
    zecs.c.timer.ecs_set_tick_source(world.raw, fast, timer);

    const slow = try world.system(.{
        .name = "Slow",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = terms },
        .callback = zecs.callback(countRateTick),
    });
    zecs.c.timer.ecs_set_tick_source(world.raw, slow, halved);

    timer_ticks = 0;
    rate_ticks = 0;

    // Eight quarter-second frames is two seconds, which is four half-second intervals.
    for (0..8) |_| _ = world.progress(0.25);

    try std.testing.expectEqual(@as(u32, 4), timer_ticks);
    try std.testing.expectEqual(@as(u32, 2), rate_ticks);
}

test "world stats move in the direction the world moved" {
    if (comptime !zecs.options.addon_stats) return error.SkipZigTest;

    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    // Tens of kilobytes of sliding windows, which is exactly why this stays a raw
    // struct and only the reading of it is wrapped.
    var stats: zecs.c.stats.ecs_world_stats_t = .{};

    zecs.c.stats.ecs_world_stats_get(world.raw, &stats);
    try std.testing.expectEqual(@as(i32, 1), zecs.stats.Window.of(&stats).at);
    const before = zecs.stats.Window.of(&stats).gauge(&stats.entities.count).avg;

    for (0..100) |_| _ = world.newEntity();

    zecs.c.stats.ecs_world_stats_get(world.raw, &stats);
    try std.testing.expectEqual(@as(i32, 2), zecs.stats.Window.of(&stats).at);
    const after = zecs.stats.Window.of(&stats).gauge(&stats.entities.count).avg;
    try std.testing.expectEqual(before + 100, after);

    _ = world.progress(1.0);
    _ = world.progress(1.0);

    zecs.c.stats.ecs_world_stats_get(world.raw, &stats);
    const frames = zecs.stats.Window.of(&stats).counter(&stats.frame.frame_count);

    // A counter carries the running total, and the same bytes a gauge reading would
    // return carry how much it grew since the previous sample.
    try std.testing.expectEqual(@as(f64, 2), frames.total);
    try std.testing.expectEqual(@as(zecs.c.core.ecs_float_t, 2), frames.rate.avg);
}

test "pipeline stats name the systems the pipeline ran, and free what they allocated" {
    if (comptime !zecs.options.addon_stats) return error.SkipZigTest;

    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const player = try world.component(Player, .{});
    const e = world.newEntity();
    world.add(e, player);

    const terms: []const zecs.Term = &.{.{ .id = player.asId() }};
    const first = try world.system(.{
        .name = "First",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = terms },
        .callback = zecs.callback(phaseRecorder('1')),
    });
    const second = try world.system(.{
        .name = "Second",
        .phase = zecs.Builtin.post_update.id(),
        .query = .{ .terms = terms },
        .callback = zecs.callback(phaseRecorder('2')),
    });

    phase_log_len = 0;
    _ = world.progress(1.0);

    var stats: zecs.stats.PipelineStats = .{};
    defer stats.deinit();

    try std.testing.expect(stats.sample(world, zecs.c.core.ecs_get_pipeline(world.raw)));

    var seen_first = false;
    var seen_second = false;
    var merge_points: usize = 0;
    for (stats.systems()) |system| {
        if (system == first) seen_first = true;
        if (system == second) seen_second = true;
        // Zero is not a system: it is where the pipeline merged its command queues.
        if (system == 0) merge_points += 1;
    }
    try std.testing.expect(seen_first);
    try std.testing.expect(seen_second);
    try std.testing.expect(merge_points >= 1);
    try std.testing.expectEqual(@as(Entity, 0), stats.systems()[stats.systems().len - 1]);

    // Sampling again reuses the vectors rather than allocating a second pair; the
    // testing allocator is what proves both that and the release below.
    try std.testing.expect(stats.sample(world, zecs.c.core.ecs_get_pipeline(world.raw)));
}

test "an alert fires while its query matches and clears when it stops" {
    if (comptime !(zecs.options.addon_alerts and zecs.options.addon_module)) return error.SkipZigTest;

    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    // flecs imports system, pipeline, timer, meta, doc, script and rest into a new
    // world, and stops there. Alerts have to be asked for.
    const module = try zecs.pipeline.importBuiltin(world, .alerts);
    try std.testing.expect(module != 0);

    const player = try world.component(Player, .{});
    const alert = try zecs.stats.alert(world, .{
        .name = "PlayerPresent",
        .query = .{ .terms = &.{.{ .id = player.asId() }} },
        .message = "a player exists",
        .severity = .warning,
    });

    const e = world.newEntity();
    world.add(e, player);

    // The two systems that evaluate alerts run on a half-second interval, so a frame
    // has to be at least that long for anything to happen.
    _ = world.progress(1.0);

    try std.testing.expectEqual(@as(i32, 1), zecs.c.alerts.ecs_get_alert_count(world.raw, e, alert));
    try std.testing.expectEqual(@as(i32, 1), zecs.c.alerts.ecs_get_alert_count(world.raw, e, 0));
    try std.testing.expect(zecs.c.alerts.ecs_get_alert(world.raw, e, alert) != 0);
    try std.testing.expectEqual(
        zecs.stats.Severity.warning.id(),
        world.getTarget(alert, zecs.c.core.FLECS_IDEcsAlertID_, 0),
    );

    world.remove(e, player);
    _ = world.progress(1.0);

    try std.testing.expectEqual(@as(i32, 0), zecs.c.alerts.ecs_get_alert_count(world.raw, e, alert));
}

test "a counter metric accumulates the number of entities with an id" {
    if (comptime !(zecs.options.addon_metrics and zecs.options.addon_module)) return error.SkipZigTest;

    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    _ = try zecs.pipeline.importBuiltin(world, .metrics);

    const player = try world.component(Player, .{});
    const players = try zecs.stats.metric(world, .{
        .name = "Players",
        .id = player.asId(),
        .kind = .counter_id,
    });

    for (0..3) |_| {
        const e = world.newEntity();
        world.add(e, player);
    }

    // The metric's system adds count * delta each frame, so one second of three
    // players is three.
    _ = world.progress(1.0);

    const value: zecs.Component(zecs.c.metrics.EcsMetricValue) = .{ .id = zecs.c.core.FLECS_IDEcsMetricValueID_ };
    try std.testing.expectEqual(@as(f64, 3), world.get(players, value).?.value);
}

var module_imports: u32 = 0;

const Physics = struct {
    pub fn import(world: zecs.World) zecs.Error!void {
        module_imports += 1;
        _ = try world.entity(.{ .name = "Gravity" });
    }
};

const Rendering = struct {
    pub fn import(world: zecs.World) void {
        module_imports += 1;
        _ = world;
    }
};

const Broken = struct {
    pub fn import(world: zecs.World) zecs.Error!void {
        _ = world;
        return zecs.Error.TooManyTerms;
    }
};

test "a module runs once per world and nests what it creates" {
    if (comptime !zecs.options.addon_module) return error.SkipZigTest;

    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    module_imports = 0;

    const physics = try zecs.pipeline.import(world, Physics);
    const again = try zecs.pipeline.import(world, Physics);

    try std.testing.expectEqual(physics, again);
    try std.testing.expectEqual(@as(u32, 1), module_imports);

    // flecs reads the module name as PascalCase and lowercases it into a path.
    try std.testing.expectEqualStrings("physics", world.getName(physics).?);

    // Everything the module made is a child of it, because flecs sets the scope for
    // the duration of the import.
    const gravity = world.lookupPath("physics.Gravity", .{});
    try std.testing.expect(gravity != 0);
    try std.testing.expectEqual(physics, world.getParent(gravity));

    // A module whose import returns nothing is just as valid.
    _ = try zecs.pipeline.import(world, Rendering);
    try std.testing.expectEqual(@as(u32, 2), module_imports);
}

test "an error raised inside a module reaches the caller" {
    if (comptime !zecs.options.addon_module) return error.SkipZigTest;

    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    // flecs's module action returns nothing, so the error has to be carried out of the
    // callback rather than through it.
    try std.testing.expectError(
        zecs.Error.TooManyTerms,
        zecs.pipeline.import(world, Broken),
    );
}

var app_frames: u32 = 0;
var app_init_ran = false;

fn appFrame(it: *zecs.Iter) void {
    _ = it;
    app_frames += 1;
}

fn appInit(world: zecs.World) void {
    app_init_ran = true;
    _ = world.newEntity();
}

test "the app loop runs a fixed number of frames and leaves the world alive" {
    if (comptime !zecs.options.addon_app) return error.SkipZigTest;

    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    const player = try world.component(Player, .{});
    const e = world.newEntity();
    world.add(e, player);

    _ = try world.system(.{
        .name = "CountFrames",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = &.{.{ .id = player.asId() }} },
        .callback = zecs.callback(appFrame),
    });

    app_frames = 0;
    app_init_ran = false;

    try zecs.app.run(world, .{
        .frames = 3,
        .delta_time = 1.0,
        .init = zecs.app.initAction(appInit),
    });

    try std.testing.expect(app_init_ran);
    try std.testing.expectEqual(@as(u32, 3), app_frames);

    // flecs's header says the world is cleaned up when the app quits. It is not: the
    // run action calls ecs_quit and nothing else, so the world is still ours to
    // destroy — and it stays quit.
    try std.testing.expect(world.shouldQuit());
    try std.testing.expect(world.isAlive(e));
    try std.testing.expect(!world.progress(1.0));
}

test "the REST component and descriptor are usable without opening a socket" {
    if (comptime !zecs.options.addon_rest) return error.SkipZigTest;

    try zecs.setAllocator(std.testing.allocator);
    const world = try zecs.World.init();
    defer world.deinit();

    // Setting this component is what starts a server, so the test stops just short of
    // it: the component exists, and nothing is listening until it is set.
    const rest = zecs.app.restComponent();
    try std.testing.expect(rest.id != 0);
    try std.testing.expect(world.get(zecs.c.core.EcsWorld, rest) == null);

    const desc = zecs.app.RestServerDesc{
        .port = 27750,
        .ipaddr = "127.0.0.1",
        .cache_timeout = 0.2,
    };
    const c_desc = desc.toC();
    try std.testing.expectEqual(@as(u16, 27750), c_desc.port);
    try std.testing.expectEqualStrings("127.0.0.1", std.mem.span(c_desc.ipaddr.?));

    // ecs_rest_server_init overwrites the reply callback with its own, so the typed
    // descriptor does not offer one to be discarded.
    try std.testing.expectEqual(@as(zecs.c.core.ecs_http_reply_action_t, null), c_desc.callback);
    try std.testing.expectEqual(@as(?*anyopaque, null), c_desc.ctx);
}

test "a component handle knows which world minted it" {
    var a = try zecs.World.init();
    defer a.deinit();
    var b = try zecs.World.init();
    defer b.deinit();

    const pos_a = try a.component(Position, .{});
    const pos_b = try b.component(Position, .{});

    // Nothing here is exotic: two worlds registering the same type in the same order
    // give it the same id, which is exactly why the number cannot be the check.
    try std.testing.expectEqual(pos_a.id, pos_b.id);

    try std.testing.expect(a.minted(pos_a));
    try std.testing.expect(b.minted(pos_b));
    try std.testing.expect(!a.minted(pos_b));
    try std.testing.expect(!b.minted(pos_a));
}

test "a handle no world minted belongs to every world" {
    var world = try zecs.World.init();
    defer world.deinit();

    // A pair of two bare entity ids is a function of its halves, not a registration.
    const likes = try world.entity(.{ .name = "Likes" });
    const apples = try world.entity(.{ .name = "Apples" });
    try std.testing.expect(world.minted(zecs.pairOf(likes, apples)));

    // A pair with a registered half carries that half's world, and is refused by
    // another one.
    var other = try zecs.World.init();
    defer other.deinit();
    const pos = try world.component(Position, .{});
    try std.testing.expect(world.minted(zecs.pairOf(pos, apples)));
    try std.testing.expect(!other.minted(zecs.pairOf(pos, apples)));

    // flecs's process-global component ids belong to no world in particular.
    try std.testing.expect(world.minted(zecs.app.restComponent()));
}

test "a handle is accepted by a stage of the world that minted it" {
    var world = try zecs.World.init();
    defer world.deinit();

    const pos = try world.component(Position, .{});
    zecs.c.world.ecs_set_stage_count(world.raw, 2);
    defer zecs.c.world.ecs_set_stage_count(world.raw, 1);

    // A stage is a different pointer for the same world, and a handle registered on
    // the world is meant to be usable from one — which is why the comparison goes
    // through `ecs_get_world` rather than comparing the pointers.
    const stage = try world.stage(0);
    try std.testing.expect(stage.minted(pos));
}
