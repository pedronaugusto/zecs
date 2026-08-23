//! What zecs costs.
//!
//! The build options this package exposes are performance choices, and a choice nobody
//! measured is a guess. This exists so the defaults can be argued from numbers:
//!
//! ```sh
//! zig build bench -Doptimize=ReleaseFast                      # block allocator (the release default)
//! zig build bench -Doptimize=ReleaseFast -Duse_os_alloc=true  # every allocation through the injected allocator
//! ```
//!
//! Everything is built one way per invocation, flecs included, so each run describes a
//! configuration that actually exists rather than a mixture.
//!
//! Each case runs several times against a fresh world and the best result is reported.
//! Microbenchmarks on a laptop are noisy — first-touch page faults, frequency scaling,
//! whatever else is running — and the minimum is the measurement least contaminated by
//! all of it. Two runs of this program should agree; if they do not, do not quote them.

const std = @import("std");
const builtin = @import("builtin");
const zecs = @import("zecs");
const bench_options = @import("bench_options");

const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };
const Tag = struct {};

/// How many times each case runs. The best is reported.
const repeats = 5;
const entity_count = 100_000;
const iteration_passes = 20;

/// Kept out of the optimizer's reach so that work with an unused result is still done.
var sink: f64 = 0;

/// Counts what flecs asks of the allocator, without changing what it gets.
///
/// The call count is the mechanism behind the `use_os_alloc` option: with flecs's block
/// allocator in play, small objects are served from pools and never reach here at all.
/// Timing shows what that is worth; this shows what it is.
const Counting = struct {
    backing: std.mem.Allocator,
    calls: std.atomic.Value(u64) = .init(0),

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.backing.rawResize(buf, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.backing.rawRemap(buf, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        self.backing.rawFree(buf, alignment, ra);
    }
};

var counting: Counting = undefined;
var locking: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;

var io: std.Io = undefined;
var arena_alloc: std.mem.Allocator = undefined;

/// A monotonic stopwatch.
///
/// Zig 0.16 moved clocks behind the `Io` interface, so timing needs an implementation
/// to read one from. The single-threaded one is enough: nothing here is asynchronous,
/// and it allocates nothing.
const Stopwatch = struct {
    start: std.Io.Timestamp,

    fn begin() Stopwatch {
        return .{ .start = .now(io, .awake) };
    }

    fn read(self: Stopwatch) u64 {
        const now: std.Io.Timestamp = .now(io, .awake);
        return @intCast(self.start.durationTo(now).nanoseconds);
    }
};

const Measurement = struct {
    ops: u64,
    nanos: u64,

    fn perOp(self: Measurement) f64 {
        if (self.ops == 0) return 0;
        return @as(f64, @floatFromInt(self.nanos)) / @as(f64, @floatFromInt(self.ops));
    }

    fn perSecond(self: Measurement) f64 {
        if (self.nanos == 0) return 0;
        return @as(f64, @floatFromInt(self.ops)) * 1_000_000_000.0 /
            @as(f64, @floatFromInt(self.nanos));
    }
};

/// Runs a case `repeats` times and prints the best result.
fn measure(name: []const u8, case: *const fn () anyerror!Measurement) !void {
    var best: ?Measurement = null;
    for (0..repeats) |_| {
        const result = try case();
        if (best == null or result.perOp() < best.?.perOp()) best = result;
    }
    const winner = best.?;
    std.debug.print("  {s: <42} {d: >9.1} ns/op  {d: >11.1} M/s\n", .{
        name,
        winner.perOp(),
        winner.perSecond() / 1_000_000.0,
    });
}

//=============================================================================
// Cases
//
// Each builds and tears down its own world, so setup is never inside the timed
// section and one case cannot leave state behind for the next.
//=============================================================================

fn createEntities() !Measurement {
    const world = try zecs.World.init();
    defer world.deinit();
    const position = try world.component(Position, .{});

    const timer = Stopwatch.begin();
    for (0..entity_count) |_| _ = world.newWith(position);
    return .{ .ops = entity_count, .nanos = timer.read() };
}

fn setComponent() !Measurement {
    const world = try zecs.World.init();
    defer world.deinit();
    const position = try world.component(Position, .{});

    const entities = try arena_alloc.alloc(zecs.Entity, entity_count);
    defer arena_alloc.free(entities);
    for (entities) |*e| e.* = world.newWith(position);

    const timer = Stopwatch.begin();
    for (entities, 0..) |e, i| {
        world.set(e, position, .{ .x = @floatFromInt(i), .y = 0, .z = 0 });
    }
    return .{ .ops = entity_count, .nanos = timer.read() };
}

fn getComponent() !Measurement {
    const world = try zecs.World.init();
    defer world.deinit();
    const position = try world.component(Position, .{});

    const entities = try arena_alloc.alloc(zecs.Entity, entity_count);
    defer arena_alloc.free(entities);
    for (entities, 0..) |*e, i| {
        e.* = world.newWith(position);
        world.set(e.*, position, .{ .x = @floatFromInt(i), .y = 0, .z = 0 });
    }

    const timer = Stopwatch.begin();
    var total: f64 = 0;
    for (entities) |e| total += world.get(e, position).?.x;
    const nanos = timer.read();
    sink += total;
    return .{ .ops = entity_count, .nanos = nanos };
}

fn addTag() !Measurement {
    const world = try zecs.World.init();
    defer world.deinit();
    const position = try world.component(Position, .{});
    const tag = try world.component(Tag, .{});

    const entities = try arena_alloc.alloc(zecs.Entity, entity_count);
    defer arena_alloc.free(entities);
    for (entities) |*e| e.* = world.newWith(position);

    const timer = Stopwatch.begin();
    for (entities) |e| world.add(e, tag);
    return .{ .ops = entity_count, .nanos = timer.read() };
}

fn removeTag() !Measurement {
    const world = try zecs.World.init();
    defer world.deinit();
    const position = try world.component(Position, .{});
    const tag = try world.component(Tag, .{});

    const entities = try arena_alloc.alloc(zecs.Entity, entity_count);
    defer arena_alloc.free(entities);
    for (entities) |*e| {
        e.* = world.newWith(position);
        world.add(e.*, tag);
    }

    const timer = Stopwatch.begin();
    for (entities) |e| world.remove(e, tag);
    return .{ .ops = entity_count, .nanos = timer.read() };
}

fn iterate(cache_kind: zecs.CacheKind) !Measurement {
    const world = try zecs.World.init();
    defer world.deinit();
    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    for (0..entity_count) |i| {
        const e = world.newEntity();
        world.set(e, position, .{ .x = @floatFromInt(i), .y = 0, .z = 0 });
        world.set(e, velocity, .{ .x = 1, .y = 1, .z = 1 });
    }

    var query = try world.query(.{
        .terms = &.{
            .{ .id = position.asId(), .inout = .read_write },
            .{ .id = velocity.asId(), .inout = .read },
        },
        .cache_kind = cache_kind,
    });
    defer query.deinit();

    // A pass to warm the cache and touch every page, so what follows is steady state.
    {
        var warm = query.iter();
        defer warm.deinit();
        while (warm.next()) |row| sink += row.fieldSelf(Position, 0)[0].x;
    }

    const timer = Stopwatch.begin();
    var visited: u64 = 0;
    for (0..iteration_passes) |_| {
        var it = query.iter();
        defer it.deinit();
        while (it.next()) |row| {
            const positions = row.fieldSelf(Position, 0);
            const velocities = row.fieldSelf(Velocity, 1);
            for (positions, velocities) |*p, v| {
                p.x += v.x;
                p.y += v.y;
                p.z += v.z;
            }
            visited += row.count();
        }
    }
    return .{ .ops = visited, .nanos = timer.read() };
}

fn iterateCached() !Measurement {
    return iterate(.auto);
}

fn iterateUncached() !Measurement {
    return iterate(.none);
}

var system_visits: std.atomic.Value(u64) = .init(0);

fn moveSystem(it: *zecs.Iter) void {
    const dt: f32 = @floatCast(it.deltaTime());
    const positions = it.fieldSelf(Position, 0);
    const velocities = it.fieldSelf(Velocity, 1);
    for (positions, velocities) |*p, v| {
        p.x += v.x * dt;
        p.y += v.y * dt;
        p.z += v.z * dt;
    }
    _ = system_visits.fetchAdd(positions.len, .monotonic);
}

fn pipeline(threads: i32, multi_threaded: bool) !Measurement {
    const world = try zecs.World.init();
    defer world.deinit();

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});

    for (0..entity_count) |i| {
        const e = world.newEntity();
        world.set(e, position, .{ .x = @floatFromInt(i), .y = 0, .z = 0 });
        world.set(e, velocity, .{ .x = 1, .y = 1, .z = 1 });
    }

    _ = try world.system(.{
        .name = "Move",
        .phase = zecs.Builtin.on_update.id(),
        .query = .{ .terms = &.{
            .{ .id = position.asId(), .inout = .read_write },
            .{ .id = velocity.asId(), .inout = .read },
        } },
        .callback = zecs.callback(moveSystem),
        .multi_threaded = multi_threaded,
    });

    if (threads > 1) world.setThreads(threads);
    _ = world.progress(0.016); // warm up, and start the workers

    system_visits.store(0, .monotonic);
    const timer = Stopwatch.begin();
    for (0..iteration_passes) |_| _ = world.progress(0.016);
    const nanos = timer.read();
    return .{ .ops = system_visits.load(.monotonic), .nanos = nanos };
}

fn pipelineSingle() !Measurement {
    return pipeline(1, false);
}

fn pipelineThreaded() !Measurement {
    return pipeline(4, true);
}

//=============================================================================

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    arena_alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    io = threaded.io();

    std.debug.print("\nzecs benchmarks\n", .{});
    std.debug.print("  optimize      {s}\n", .{@tagName(builtin.mode)});
    std.debug.print("  use_os_alloc  {}\n", .{zecs.options.use_os_alloc});
    std.debug.print("  debug_checks  {s}\n", .{@tagName(zecs.options.debug_checks)});
    std.debug.print("  entities      {d}, best of {d}\n", .{ entity_count, repeats });

    if (builtin.mode == .Debug) {
        std.debug.print(
            "  NOTE: this is a Debug build. flecs is compiled with its sanitize-level\n" ++
                "  checks and Zig's C sanitizer, both of which dominate these numbers.\n" ++
                "  Re-run with -Doptimize=ReleaseFast for figures worth quoting.\n\n",
            .{},
        );
    }

    // Which allocator flecs gets. The default is a fast thread-local one, so the
    // numbers measure flecs; `locking` is a mutex-guarded checking allocator, which is
    // what a host debugging its memory would inject — and the configuration where how
    // often flecs calls out actually costs something.
    const wants_locking = bench_options.locking_allocator;
    counting = .{ .backing = if (wants_locking) locking.allocator() else std.heap.smp_allocator };
    std.debug.print("  allocator     {s}\n\n", .{if (wants_locking) "locking (DebugAllocator)" else "smp"});
    try zecs.setAllocator(counting.allocator());

    try measure("create entity with one component", createEntities);
    try measure("set a component by entity", setComponent);
    try measure("get a component by entity", getComponent);
    try measure("add a tag (moves the entity's table)", addTag);
    try measure("remove a tag (moves it back)", removeTag);
    try measure("query iteration, cached", iterateCached);
    try measure("query iteration, uncached", iterateUncached);
    try measure("progress, single threaded", pipelineSingle);
    try measure("progress, 4 threads", pipelineThreaded);

    std.debug.print("\n  allocator calls from flecs: {d}\n\n", .{counting.calls.load(.monotonic)});

    // Keeps the accumulated work from being optimized away.
    if (sink == 12345.6789) std.debug.print("", .{});
}
