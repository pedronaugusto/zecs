//! Movement in an ECS: two components, one system, ten frames.
//!
//! Everything here is what a consumer writes — there are no privileged imports and no
//! test helpers. If something in this file stops compiling, the public API changed.

const std = @import("std");
const zecs = @import("zecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

/// What the system matches, written as a type because the callback's parameter needs it
/// before `main` has registered anything. A component handle is a runtime value — a
/// component belongs to a world, not to the program — but its TYPE is what carries
/// `Position` and `Velocity` into the row, and that is known here.
///
/// The terms the system is built with and the slices `move` reads both come from this one
/// declaration, so inserting a term cannot leave the loop reading the wrong component.
const Movers = struct {
    zecs.Component(Position),
    zecs.In(zecs.Component(Velocity)),
};

/// A system callback receives one matched table at a time, so the loop is over contiguous
/// slices rather than one lookup per entity — which is the reason to use an archetype ECS
/// at all. `row.fields` is a tuple in spec order: `[]Position` and `[]const Velocity`.
fn move(row: zecs.RowOf(Movers)) void {
    const dt: f32 = @floatCast(row.deltaTime());
    const p, const v = row.fields;
    for (p, v) |*pos, vel| {
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;
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

    const movers: Movers = .{ position, zecs.in(velocity) };
    _ = try world.system(.{
        .name = "Move",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = &zecs.SpecOf(Movers).build(movers) },
        .callback = zecs.rowCallback(Movers, move),
    });

    for (0..10) |_| _ = world.progress(1.0 / 60.0);

    const p = world.get(e, position).?;
    std.debug.print("position after 10 frames: {d:.4}, {d:.4}\n", .{ p.x, p.y });

    // The raw layer is a consumer-facing API too, not an internal detail: every symbol
    // flecs exports is declared, under its own name.
    const info = zecs.c.world.ecs_get_build_info();
    std.debug.print("flecs {s}\n", .{info.version.?});
}
