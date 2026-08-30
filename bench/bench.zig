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
//! ## Two arms, because one number means nothing
//!
//! Every case is printed under a BASELINE that does the same arithmetic over plain Zig
//! slices at the same entity count. The baseline is not a competitor — an archetype ECS
//! is not trying to beat a hand-rolled array, it is trying to stay near one while
//! letting the set of components vary per entity. It is there so the numbers above it
//! can be read at all: "query iteration" at 1.4x the floor and at 14x the floor are
//! different claims, and without the floor on the same machine, in the same build, in
//! the same run, neither can be made. A ns/op on its own describes the laptop.
//!
//! ## What one run is
//!
//! Each case is built and torn down from scratch, run once as a discarded warm-up, then
//! run `repeats` times, and the best is reported. The warm-up belongs to the harness
//! rather than to the cases, so a case added later cannot forget it — which is exactly
//! how the two cases that had one and the seven that did not came about.
//!
//! The minimum, not the mean: microbenchmarks on a laptop are noisy — first-touch page
//! faults, frequency scaling, whatever else is running — and the minimum is the sample
//! least contaminated by all of it. Two runs of this program should agree; if they do
//! not, do not quote them.
//!
//! ## Blind spots — what these numbers do not control for
//!
//! Say them here rather than discover them in an argument later.
//!
//!  - **The machine is not held still.** No CPU pinning, no frequency governor, no
//!    isolation from whatever else is running. Best-of-N is a defence, not a fix.
//!  - **The allocator call counter is inside the timed region.** `Counting` does one
//!    relaxed atomic add per call, and the cases that allocate pay it. It is only
//!    reached on a real allocation — never inside the iteration loops — so it moves
//!    creation and table-move numbers slightly and iteration numbers not at all.
//!  - **One table.** Every entity in a case has the same components, so nothing here
//!    measures matching against many archetypes, which is where an ECS query actually
//!    spends its time in a real world.
//!  - **One shape of data.** Three-float components, no pointers, no lifecycle hooks.
//!    A component with a destructor moves tables at a different price entirely.
//!  - **Nothing is compared against another ECS.** These numbers say what zecs costs on
//!    the machine that ran them; they say nothing about anyone else's.
//!
//! The header of every run records the date, the compiler, the target and the CPU, so a
//! number pasted somewhere can be traced back to the run that produced it. A number
//! quoted without that header is not evidence of anything.

const std = @import("std");
const builtin = @import("builtin");
const zecs = @import("zecs");
const bench_options = @import("bench_options");

const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };
const Tag = struct {};

/// How many times each case runs after the discarded warm-up. The best is reported.
const repeats = 5;
const entity_count = 100_000;
const iteration_passes = 20;

/// The delta time every pipeline pass is given.
///
/// Exactly one, and not a plausible frame time, because the check that the system ran
/// is arithmetic on the result: with a velocity of one and a step of one, a position
/// advances by exactly one per pass and stays exact in f32 well past the pass count.
/// A step of 0.016 would accumulate rounding and turn a correctness check into a
/// tolerance argument.
const step: f32 = 1.0;

/// Kept out of the optimizer's reach so that work with an unused result is still done.
var sink: f64 = 0;

/// Counts what flecs asks of the allocator, without changing what it gets.
///
/// The call count is the mechanism behind the `use_os_alloc` option: with flecs's block
/// allocator in play, small objects are served from pools and never reach here at all.
/// Timing shows what that is worth; this shows what it is.
///
/// The atomic add is a known contaminant, recorded in the blind spots above: it is one
/// relaxed increment per allocator call, which the allocating cases pay and the
/// iterating ones never reach.
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

const Case = *const fn () anyerror!Measurement;

/// The floor a case is read against, filled in by `baseline` and read by `measure`.
var floor: ?f64 = null;

/// Runs `case` once to warm up, throws that away, runs it `repeats` more times and
/// prints the best.
///
/// The warm-up is here rather than in the cases because a case cannot be trusted to
/// remember it: the first run of anything touches pages for the first time, grows the
/// allocator's arenas for the first time, and resolves the first branch predictions,
/// none of which is what the case is about.
fn run(name: []const u8, case: Case) !Measurement {
    _ = try case();

    var best: ?Measurement = null;
    for (0..repeats) |_| {
        const result = try case();
        if (best == null or result.perOp() < best.?.perOp()) best = result;
    }
    const winner = best.?;

    std.debug.print("  {s: <42} {d: >9.1} ns/op  {d: >11.1} M/s", .{
        name,
        winner.perOp(),
        winner.perSecond() / 1_000_000.0,
    });
    if (floor) |f| {
        if (f > 0) std.debug.print("  {d: >6.1}x floor", .{winner.perOp() / f});
    }
    std.debug.print("\n", .{});
    return winner;
}

/// Runs a case and makes it the floor the cases after it are printed against.
fn baseline(name: []const u8, case: Case) !void {
    floor = null;
    const result = try run(name, case);
    floor = result.perOp();
}

/// Runs a case against the current floor.
fn measure(name: []const u8, case: Case) !void {
    _ = try run(name, case);
}

fn section(name: []const u8) void {
    floor = null;
    std.debug.print("\n  {s}\n", .{name});
}

//=============================================================================
// The floor
//
// The same arithmetic over plain Zig slices. Not a competitor: the point of an ECS is
// that the set of components varies per entity, which an array of structs cannot do at
// all. These exist so the numbers above them have a scale.
//=============================================================================

fn floorRead() !Measurement {
    const positions = try arena_alloc.alloc(Position, entity_count);
    defer arena_alloc.free(positions);
    for (positions, 0..) |*p, i| p.* = .{ .x = @floatFromInt(i), .y = 0, .z = 0 };

    const timer = Stopwatch.begin();
    var total: f64 = 0;
    for (positions) |p| total += p.x;
    const nanos = timer.read();
    sink += total;
    return .{ .ops = entity_count, .nanos = nanos };
}

fn floorIterate() !Measurement {
    const positions = try arena_alloc.alloc(Position, entity_count);
    defer arena_alloc.free(positions);
    const velocities = try arena_alloc.alloc(Velocity, entity_count);
    defer arena_alloc.free(velocities);
    for (positions, velocities, 0..) |*p, *v, i| {
        p.* = .{ .x = @floatFromInt(i), .y = 0, .z = 0 };
        v.* = .{ .x = 1, .y = 1, .z = 1 };
    }

    const timer = Stopwatch.begin();
    for (0..iteration_passes) |_| {
        for (positions, velocities) |*p, v| {
            p.x += v.x;
            p.y += v.y;
            p.z += v.z;
        }
    }
    const nanos = timer.read();
    sink += positions[0].x;
    return .{ .ops = entity_count * iteration_passes, .nanos = nanos };
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
        .options = .{ .cache_kind = cache_kind },
    });
    defer query.deinit();

    // A pass to fill the query's cache and touch every page, so what follows is steady
    // state. The harness warms the process; this warms the world, which is built fresh
    // by every run and so cannot be warmed from outside.
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
    const nanos = timer.read();
    if (visited != entity_count * iteration_passes) return error.QueryMissedAnEntity;
    return .{ .ops = visited, .nanos = nanos };
}

fn iterateCached() !Measurement {
    return iterate(.auto);
}

fn iterateUncached() !Measurement {
    return iterate(.none);
}

fn moveSystem(it: *zecs.Iter) void {
    const dt: f32 = @floatCast(it.deltaTime());
    const positions = it.fieldSelf(Position, 0);
    const velocities = it.fieldSelf(Velocity, 1);
    for (positions, velocities) |*p, v| {
        p.x += v.x * dt;
        p.y += v.y * dt;
        p.z += v.z * dt;
    }
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

    var passes: u64 = 0;
    _ = world.progress(step); // warm up the world, and start the workers
    passes += 1;

    const timer = Stopwatch.begin();
    for (0..iteration_passes) |_| _ = world.progress(step);
    const nanos = timer.read();
    passes += iteration_passes;

    // What proves the system ran, with nothing in the timed loop that could have been
    // measuring itself. The counter this replaced was an atomic add inside the system
    // callback — contended across four threads in exactly the arm where contention is
    // the thing being measured. The data says the same and says it more: `y` started at
    // zero and advances by exactly `step` per pass, so a system that stopped matching, a
    // threaded run that dropped part of the table, and a threaded run that covered part
    // of it twice are all three visible here and none of them was visible in a total.
    const expected = @as(f32, @floatFromInt(passes)) * step;
    var checked: u64 = 0;
    var it = world.each(position);
    defer it.deinit();
    while (it.next()) |row| {
        for (row.fieldSelf(Position, 0)) |p| {
            if (p.y != expected) return error.SystemDidNotVisitEveryEntityExactlyOnce;
            checked += 1;
        }
    }
    if (checked != entity_count) return error.SystemDidNotVisitEveryEntityExactlyOnce;

    return .{ .ops = entity_count * iteration_passes, .nanos = nanos };
}

fn pipelineSingle() !Measurement {
    return pipeline(1, false);
}

fn pipelineThreaded() !Measurement {
    return pipeline(4, true);
}

//=============================================================================

/// The run's provenance, printed so a number pasted elsewhere can be traced back to it.
fn printHeader(wants_locking: bool) void {
    const now = std.Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
    const stamp: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const year_day = stamp.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = stamp.getDaySeconds();

    std.debug.print("\nzecs benchmarks\n", .{});
    std.debug.print("  date          {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\n", .{
        year_day.year,
        @intFromEnum(month_day.month),
        @as(u16, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
    std.debug.print("  zecs          {f}, flecs {f}\n", .{ zecs.version, zecs.flecs_version });
    std.debug.print("  zig           {f}\n", .{builtin.zig_version});
    std.debug.print("  target        {s}-{s}-{s}\n", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
    });
    std.debug.print("  cpu           {s}\n", .{builtin.cpu.model.name});
    std.debug.print("  optimize      {s}\n", .{@tagName(builtin.mode)});
    std.debug.print("  use_os_alloc  {}\n", .{zecs.options.use_os_alloc});
    std.debug.print("  debug_checks  {s}\n", .{@tagName(zecs.options.debug_checks)});
    std.debug.print("  entities      {d}, best of {d} after a discarded warm-up\n", .{
        entity_count, repeats,
    });
    std.debug.print("  allocator     {s}\n", .{
        if (wants_locking) "locking (DebugAllocator)" else "smp",
    });

    if (builtin.mode == .Debug) {
        std.debug.print(
            "\n  NOTE: this is a Debug build. flecs is compiled with its sanitize-level\n" ++
                "  checks and Zig's C sanitizer, both of which dominate these numbers.\n" ++
                "  Re-run with -Doptimize=ReleaseFast for figures worth quoting.\n",
            .{},
        );
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    arena_alloc = arena.allocator();

    var threaded: std.Io.Threaded = .init_single_threaded;
    io = threaded.io();

    // Which allocator flecs gets. The default is a fast thread-local one, so the
    // numbers measure flecs; `locking` is a mutex-guarded checking allocator, which is
    // what a host debugging its memory would inject — and the configuration where how
    // often flecs calls out actually costs something.
    const wants_locking = bench_options.locking_allocator;
    counting = .{ .backing = if (wants_locking) locking.allocator() else std.heap.smp_allocator };
    printHeader(wants_locking);
    try zecs.setAllocator(counting.allocator());

    section("one entity at a time");
    try baseline("FLOOR: read a field from a plain array", floorRead);
    try measure("create entity with one component", createEntities);
    try measure("set a component by entity", setComponent);
    try measure("get a component by entity", getComponent);
    try measure("add a tag (moves the entity's table)", addTag);
    try measure("remove a tag (moves it back)", removeTag);

    section("over every entity");
    try baseline("FLOOR: the same math over two plain slices", floorIterate);
    try measure("query iteration, cached", iterateCached);
    try measure("query iteration, uncached", iterateUncached);
    try measure("progress, single threaded", pipelineSingle);
    try measure("progress, 4 threads", pipelineThreaded);

    std.debug.print("\n  allocator calls from flecs: {d}\n\n", .{counting.calls.load(.monotonic)});

    // Keeps the accumulated work from being optimized away.
    if (sink == 12345.6789) std.debug.print("", .{});
}
