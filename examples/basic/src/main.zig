//! Movement in an ECS: two components, one system, ten frames.
//!
//! Everything here is what a consumer writes — there are no privileged imports and no
//! test helpers. If something in this file stops compiling, the public API changed.

const std = @import("std");
const zecs = @import("zecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

/// A system callback receives the iterator, not the entities. `fieldSelf` hands back a
/// slice of the whole matched table, so the loop below is over contiguous memory rather
/// than one lookup per entity — which is the reason to use an archetype ECS at all.
fn move(it: *zecs.Iter) void {
    const dt: f32 = @floatCast(it.deltaTime());
    for (it.fieldSelf(Position, 0), it.fieldSelf(Velocity, 1)) |*p, v| {
        p.x += v.x * dt;
        p.y += v.y * dt;
    }
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    // Before the first world, and only before it: flecs latches its OS API on first use
    // and swapping an allocator while it holds live blocks would free them to the wrong
    // one. The package refuses rather than letting that happen.
    try zecs.setAllocator(gpa);
    // Registered before the world's own `defer`, so it runs after it. Fallible because
    // it is `setAllocator` in disguise and that refuses while a world is alive; by the
    // time this runs the world is gone, so it cannot fail — the compiler just does not
    // know that.
    defer zecs.resetAllocator() catch {};

    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    const e = world.newEntity();
    world.set(e, position, .{ .x = 0, .y = 0 });
    world.set(e, velocity, .{ .x = 1, .y = 2 });

    _ = try world.system(.{
        .name = "Move",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = &.{
            .{ .id = position.asId(), .inout = .read_write },
            .{ .id = velocity.asId(), .inout = .read },
        } },
        .callback = zecs.callback(move),
    });

    for (0..10) |_| _ = world.progress(1.0 / 60.0);

    const p = world.get(e, position).?;
    std.debug.print("position after 10 frames: {d:.4}, {d:.4}\n", .{ p.x, p.y });

    // The raw layer is a consumer-facing API too, not an internal detail: every symbol
    // flecs exports is declared, under its own name.
    const info = zecs.c.ecs_get_build_info();
    std.debug.print("flecs {s}\n", .{info.version.?});
}
