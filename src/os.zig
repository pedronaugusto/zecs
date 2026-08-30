//! flecs's process-wide OS API, and the parts of it this package routes into Zig.
//!
//! flecs reaches the outside world through one struct of forty-odd function pointers.
//! It is process-wide, it can be replaced exactly once, and this file is what replaces
//! it — so this file is the only place any of those pointers can be routed from. Two
//! owners of that struct would be two things that each believe they installed it.
//!
//! What is routed here, and what is deliberately left alone:
//!
//!   * **allocation** — the reason this seam exists, and the rest of this comment.
//!   * **`log_`, `abort_`, and the two perf-trace hooks** — see "The rest of the OS
//!     API" below. A host with its own logging, its own crash handling or its own
//!     profiler has no other way to see what flecs is doing, and each of them defaults
//!     to flecs's own behaviour until a handler is installed.
//!   * **threads, mutexes, condition variables, the clock, `dlopen`, `fopen`** — left
//!     to flecs's defaults, which its OS API implementation addon supplies on every
//!     target this package supports. Routing those would mean reimplementing the
//!     platform rather than observing flecs, and there is nothing here that could do it
//!     better than the platform does.
//!
//! ## The shape of the seam
//!
//! flecs allocates through four function pointers on a process-wide struct — malloc,
//! calloc, realloc, free — with C's contract: no alignment is ever requested, and free
//! is handed a bare pointer with no size. Zig's allocator interface needs both back at
//! free time, so each block carries a 16-byte header immediately before the pointer
//! flecs sees:
//!
//! ```text
//!   base                    returned pointer
//!    |                       |
//!    v                       v
//!   [ 16-byte header ][ ....... payload ....... ]
//! ```
//!
//! Sixteen bytes rather than eight: that is the alignment C's `malloc` guarantees on
//! every target this package supports, and flecs stores component data in these blocks.
//! A component containing a SIMD vector has to land aligned without being asked for.
//!
//! ## Installing it, and the two ways that goes wrong
//!
//! flecs will accept an allocator at a point where accepting it is not safe, so the
//! guards here are the interesting part rather than the bridge itself:
//!
//! - The full `ecs_os_set_api_defaults` → `ecs_os_get_api` → patch → `ecs_os_set_api`
//!   sequence is always performed. Patching a zeroed struct instead leaves the logging,
//!   abort, clock and threading callbacks null, and flecs calls one of them during
//!   world creation — a jump to address zero, some distance from the cause.
//! - Installing after a world exists is refused. flecs's own behaviour here is worse
//!   than a silent no-op: with the OS API implementation addon compiled in, which is
//!   the default, a late call succeeds and swaps the allocator while flecs holds live
//!   blocks from the previous one.
//!
//! Both are errors, not assertions, because a host that gets its start-up order wrong
//! deserves a diagnosis rather than a crash in a release build.
//!
//! ## Scope
//!
//! One allocator, process-wide, because that is what flecs's OS API is. It is surfaced
//! rather than hidden behind a per-world parameter that could not be honoured.
//!
//! If systems are run on more than one thread, flecs allocates from those threads, so
//! the allocator must be thread-safe. That is the host's contract to keep; the suite
//! exercises it with a threaded pipeline.

const std = @import("std");
const c = @import("c/os.zig");
// The callback table itself is a linked symbol declared in the core module, and
// `c/os.zig` cannot re-export it: a `pub const` alias of an `extern var` is a
// compile-time constant where the ABI guard expects a symbol, and it says so.
const core = @import("c/core.zig");
const options = @import("zecs_options");
const Error = @import("error.zig").Error;

//=============================================================================
// Block layout
//=============================================================================

/// Alignment handed to flecs. C's `malloc` guarantees this much, flecs assumes it for
/// component storage, and nothing in flecs ever asks for more.
///
/// Public so that `component.max_alignment` — the bound the typed layer refuses over —
/// can be compared against it rather than kept in step by hand. One number, two users.
pub const payload_alignment: std.mem.Alignment = .@"16";

const Header = struct {
    /// Total bytes taken from the backing allocator, header included.
    total: usize,
};

/// Distance from the base of an allocation to the pointer flecs receives.
const prefix: usize = payload_alignment.forward(@sizeOf(Header));

comptime {
    // The payload only stays aligned if the prefix is a whole number of alignments.
    std.debug.assert(prefix % payload_alignment.toByteUnits() == 0);
}

//=============================================================================
// Process-wide state
//=============================================================================

/// The allocator flecs is currently pointed at.
var installed: std.mem.Allocator = undefined;

/// Whether the callbacks below are the ones flecs holds. Once true it stays true:
/// flecs's OS API cannot be uninstalled, only redirected.
var callbacks_installed: bool = false;

/// Worlds alive right now, as far as this package can see. Worlds created through the
/// raw C API are invisible here, so the allocation counters are consulted too.
///
/// Atomic because flecs is usable from more than one thread and nothing stops a host
/// from creating and destroying worlds on two of them: a plain `+= 1` is a read, an
/// add and a write, and two of those interleaved lose a world. Losing one here means
/// `setAllocator` believes no world exists and swaps the allocator under a live one.
var worlds_alive: std.atomic.Value(usize) = .init(0);

/// Live bytes and blocks. Only maintained when `-Dtrack_allocations` is on, which
/// defaults to Debug: in a release build these are not compiled at all, so the bridge
/// carries no atomics on the allocation path.
var live_bytes: std.atomic.Value(usize) = .init(0);
var live_blocks: std.atomic.Value(usize) = .init(0);
var total_allocations: std.atomic.Value(usize) = .init(0);

inline fn noteAllocated(total: usize) void {
    if (comptime !options.track_allocations) return;
    _ = live_bytes.fetchAdd(total, .monotonic);
    _ = live_blocks.fetchAdd(1, .monotonic);
    _ = total_allocations.fetchAdd(1, .monotonic);
}

inline fn noteFreed(total: usize) void {
    if (comptime !options.track_allocations) return;
    _ = live_bytes.fetchSub(total, .monotonic);
    _ = live_blocks.fetchSub(1, .monotonic);
}

//=============================================================================
// The callbacks flecs holds
//=============================================================================

fn allocate(size: c.ecs_size_t) callconv(.c) ?*anyopaque {
    // flecs asserts internally that this is positive, and that assert is gone under
    // NDEBUG. A refusal is a defined answer flecs handles; malloc(0) is not.
    if (size <= 0) return null;

    const total = prefix + @as(usize, @intCast(size));
    const base = installed.rawAlloc(total, payload_alignment, @returnAddress()) orelse return null;

    const payload = base + prefix;
    header(payload).* = .{ .total = total };
    noteAllocated(total);
    return @ptrCast(payload);
}

fn allocateZeroed(size: c.ecs_size_t) callconv(.c) ?*anyopaque {
    const block = allocate(size) orelse return null;
    const bytes: [*]u8 = @ptrCast(block);
    @memset(bytes[0..@intCast(size)], 0);
    return block;
}

fn reallocate(block: ?*anyopaque, size: c.ecs_size_t) callconv(.c) ?*anyopaque {
    const payload: [*]u8 = @ptrCast(block orelse return allocate(size));
    if (size <= 0) {
        release(block);
        return null;
    }

    const old_total = header(payload).total;
    const new_total = prefix + @as(usize, @intCast(size));
    const base = payload - prefix;

    // Ask for growth in place first. For flecs's larger buffers this turns a resize
    // into a no-op instead of an allocate-copy-free.
    if (installed.rawRemap(base[0..old_total], payload_alignment, new_total, @returnAddress())) |moved| {
        const new_payload = moved + prefix;
        header(new_payload).* = .{ .total = new_total };
        if (comptime options.track_allocations) {
            _ = live_bytes.fetchAdd(new_total, .monotonic);
            _ = live_bytes.fetchSub(old_total, .monotonic);
        }
        return @ptrCast(new_payload);
    }

    const fresh = allocate(size) orelse return null;
    const copied = @min(old_total - prefix, @as(usize, @intCast(size)));
    const dst: [*]u8 = @ptrCast(fresh);
    @memcpy(dst[0..copied], payload[0..copied]);
    release(block);
    return fresh;
}

fn release(block: ?*anyopaque) callconv(.c) void {
    const payload: [*]u8 = @ptrCast(block orelse return);
    const total = header(payload).total;
    const base = payload - prefix;
    noteFreed(total);
    installed.rawFree(base[0..total], payload_alignment, @returnAddress());
}

inline fn header(payload: [*]u8) *Header {
    return @ptrCast(@alignCast(payload - @sizeOf(Header)));
}

//=============================================================================
// Installation
//=============================================================================

/// Routes every subsequent flecs allocation through `gpa`.
///
/// Call once during start-up, before creating a world. Process-wide, for as long as the
/// process lives: flecs's OS API can be redirected but never uninstalled.
///
/// Calling it again with a different allocator is allowed while no world exists and no
/// blocks are outstanding, which is what makes a test suite able to use a checking
/// allocator per test.
pub fn setAllocator(gpa: std.mem.Allocator) Error!void {
    if (worlds_alive.load(.acquire) != 0) return Error.WorldAlreadyExists;

    if (!callbacks_installed) {
        // flecs's own allocator having served anything means flecs has already run in
        // this process — a world made through the raw C API, which `worlds_alive`
        // cannot see. Its blocks would later be freed through `gpa`.
        //
        // The counters live in flecs's default implementation, so they say nothing once
        // the callbacks are replaced. That is exactly the window this checks.
        if (comptime !options.disable_counters) {
            if (flecsAllocationCount() != 0) return Error.FlecsAlreadyAllocated;
        }
    } else if (comptime options.track_allocations) {
        if (live_blocks.load(.monotonic) != 0) return Error.AllocationsOutstanding;
    }

    installed = gpa;
    if (callbacks_installed) return;

    // The full sequence, in this order. See the module comment for what skipping the
    // first call does.
    c.ecs_os_set_api_defaults();
    var api = c.ecs_os_get_api();
    api.malloc_ = allocate;
    api.calloc_ = allocateZeroed;
    api.realloc_ = reallocate;
    api.free_ = release;
    c.ecs_os_set_api(&api);

    // `ecs_os_set_api` is a no-op once flecs's OS API is initialized, and reports
    // nothing. Read back rather than assume.
    const landed = c.ecs_os_get_api();
    if (landed.malloc_ != @as(c.ecs_os_api_malloc_t, allocate)) return Error.OsApiLocked;

    callbacks_installed = true;
}

/// Points flecs back at libc's allocator.
///
/// Not an uninstall: flecs offers no way to take its OS API back, so the callbacks
/// installed above stay installed and are redirected instead. The distinction matters
/// only if you were expecting flecs's own allocator afterwards — you get libc's, which
/// is what flecs's own is.
///
/// Fallible, because it is `setAllocator` in disguise and that refuses while a world is
/// alive — swapping the allocator under a live world would free its blocks to something
/// that never allocated them. So the idiom is
///
/// ```zig
/// const world = try zecs.World.init();
/// defer world.deinit();
/// defer zecs.resetAllocator() catch {};   // runs after world.deinit(), so it cannot fail
/// ```
///
/// with the reset registered *before* the world's own `defer` so it runs after it. If a
/// world really is still alive, the error is the right answer and swallowing it leaves
/// the host's allocator installed, which is the safe state rather than the broken one.
pub fn resetAllocator() Error!void {
    try setAllocator(std.heap.c_allocator);
}

/// Whether flecs is currently allocating through this bridge.
pub fn allocatorInstalled() bool {
    return callbacks_installed;
}

fn flecsAllocationCount() i64 {
    return c.ecs_os_api_malloc_count + c.ecs_os_api_calloc_count + c.ecs_os_api_realloc_count;
}

/// Called by `World` so the guard in `setAllocator` can see worlds this package made.
pub fn noteWorldCreated() void {
    _ = worlds_alive.fetchAdd(1, .release);
}

/// The floor at zero is a compare-and-swap rather than a load and a subtract: a world
/// destroyed on each of two threads would otherwise both read one, both subtract, and
/// leave the count at the largest `usize` there is.
pub fn noteWorldDestroyed() void {
    var seen = worlds_alive.load(.monotonic);
    while (seen != 0) {
        seen = worlds_alive.cmpxchgWeak(seen, seen - 1, .release, .monotonic) orelse return;
    }
}

//=============================================================================
// The rest of the OS API
//
// Three hooks a host cannot reach any other way, installed the way flecs installs its
// own: by writing the field of `ecs_os_api` rather than by handing over a new struct.
// `ecs_os_set_api` takes effect exactly once (flecs.c:18686-18693), so after the
// allocator is in place a whole-struct replacement is silently a no-op — which is why
// `setAllocator` reads back what landed, and why these do not use that route at all.
//
// Order does not matter. Installed before the allocator, a handler survives, because
// `setAllocator` copies the live struct before patching it; installed after, it is
// written straight into the struct flecs is already calling.
//=============================================================================

/// What flecs installed, so that removing a handler puts its own behaviour back rather
/// than leaving a null pointer where flecs expects something callable.
var flecs_default: struct {
    log: c.ecs_os_api_log_t = null,
    abort: c.ecs_os_api_abort_t = null,
    trace_push: c.ecs_os_api_perf_trace_t = null,
    trace_pop: c.ecs_os_api_perf_trace_t = null,
} = .{};
var defaults_captured: bool = false;

/// Fills in flecs's own callbacks if nothing has yet, and records them.
///
/// `ecs_os_set_api_defaults` returns immediately once the API is initialized
/// (flecs.c:19203-19212), and does not lock it when it is not — with the OS API
/// implementation addon compiled in it explicitly clears the initialized flag again
/// (flecs.c:19247-19250). So this is safe to call at any point, including before
/// `setAllocator`, which is what makes the order of the two irrelevant.
fn captureDefaults() void {
    if (defaults_captured) return;
    c.ecs_os_set_api_defaults();
    const api = c.ecs_os_get_api();
    flecs_default = .{
        .log = api.log_,
        .abort = api.abort_,
        .trace_push = api.perf_trace_push_,
        .trace_pop = api.perf_trace_pop_,
    };
    defaults_captured = true;
}

/// How bad flecs thinks a message is. The numbers are flecs's own — `ecs_warn` is
/// `ecs_log_(-2, …)` and `ecs_dbg_1` is `ecs_log_(1, …)`, libs/flecs/flecs.h:12846-12892
/// — and the enum is open because `ecs_log_` takes an `int` and nothing stops a host
/// from logging at a level of its own.
pub const LogLevel = enum(i32) {
    fatal = -4,
    err = -3,
    warning = -2,
    trace = 0,
    debug_1 = 1,
    debug_2 = 2,
    debug_3 = 3,
    _,
};

/// Called for every line flecs would otherwise print itself. `file` is null for a
/// message flecs did not attribute to a source location.
pub const LogHandler = *const fn (
    level: LogLevel,
    file: ?[:0]const u8,
    line: i32,
    message: [:0]const u8,
) void;

/// Called instead of `abort()` when flecs has decided it cannot continue.
///
/// `noreturn`, and not by preference: flecs calls this from `ecs_abort_` and
/// `ecs_throw_` at a point where it has already given up on the world's invariants,
/// and its own default is libc's `abort`. A handler that returned would send flecs on
/// through code it has just declared unreachable.
pub const AbortHandler = *const fn () noreturn;

/// Called around the spans flecs marks for a profiler. Both halves are given together,
/// because a profiler that saw only one of them would be worse than one that saw
/// neither. flecs installs no default for these, so with no handler they stay null and
/// flecs skips them.
pub const TraceHandler = struct {
    push: *const fn (file: ?[:0]const u8, line: usize, name: ?[:0]const u8) void,
    pop: *const fn (file: ?[:0]const u8, line: usize, name: ?[:0]const u8) void,
};

var log_handler: ?LogHandler = null;
var abort_handler: ?AbortHandler = null;
var trace_handler: ?TraceHandler = null;

fn logThunk(
    level: i32,
    file: ?[*:0]const u8,
    line: i32,
    message: ?[*:0]const u8,
) callconv(.c) void {
    const handler = log_handler orelse return;
    handler(
        @enumFromInt(level),
        if (file) |f| std.mem.span(f) else null,
        line,
        if (message) |m| std.mem.span(m) else "",
    );
}

fn abortThunk() callconv(.c) void {
    const handler = abort_handler orelse @panic("zecs: flecs aborted");
    handler();
}

fn tracePushThunk(file: ?[*:0]const u8, line: usize, name: ?[*:0]const u8) callconv(.c) void {
    const handler = trace_handler orelse return;
    handler.push(
        if (file) |f| std.mem.span(f) else null,
        line,
        if (name) |n| std.mem.span(n) else null,
    );
}

fn tracePopThunk(file: ?[*:0]const u8, line: usize, name: ?[*:0]const u8) callconv(.c) void {
    const handler = trace_handler orelse return;
    handler.pop(
        if (file) |f| std.mem.span(f) else null,
        line,
        if (name) |n| std.mem.span(n) else null,
    );
}

/// Sends flecs's diagnostics to `handler` instead of to stderr. Null puts flecs's own
/// implementation back.
///
/// This changes where the messages go, not which of them exist: the level flecs logs at
/// is `zecs.c.log.ecs_log_set_level`.
pub fn setLogHandler(handler: ?LogHandler) void {
    captureDefaults();
    log_handler = handler;
    core.ecs_os_api.log_ = if (handler == null) flecs_default.log else &logThunk;
}

/// Replaces libc's `abort` for the paths where flecs gives up. Null puts it back.
pub fn setAbortHandler(handler: ?AbortHandler) void {
    captureDefaults();
    abort_handler = handler;
    core.ecs_os_api.abort_ = if (handler == null) flecs_default.abort else &abortThunk;
}

/// Routes flecs's profiler spans to `handler`. Null puts flecs's own back, which on
/// every build of flecs 4.1.6 means none.
pub fn setTraceHandler(handler: ?TraceHandler) void {
    captureDefaults();
    trace_handler = handler;
    core.ecs_os_api.perf_trace_push_ =
        if (handler == null) flecs_default.trace_push else &tracePushThunk;
    core.ecs_os_api.perf_trace_pop_ =
        if (handler == null) flecs_default.trace_pop else &tracePopThunk;
}

//=============================================================================
// Statistics
//=============================================================================

pub const Stats = struct {
    /// Bytes currently held by flecs, headers included.
    live_bytes: usize,
    /// Blocks currently held by flecs.
    live_blocks: usize,
    /// Allocations served since the bridge was installed.
    total_allocations: usize,
};

/// What flecs is currently holding, or null when built without `-Dtrack_allocations`.
///
/// Note what "currently holding" means: with the block allocator in play — the release
/// default — flecs serves most small objects from pools of its own, so these numbers
/// describe the pools rather than individual objects. Build with `-Duse_os_alloc=true`
/// to see every allocation, which is what a Debug build does already.
pub fn stats() ?Stats {
    if (comptime !options.track_allocations) return null;
    return .{
        .live_bytes = live_bytes.load(.monotonic),
        .live_blocks = live_blocks.load(.monotonic),
        .total_allocations = total_allocations.load(.monotonic),
    };
}

//=============================================================================
// Tests
//=============================================================================

const testing = std.testing;

test "the bridge round-trips through the C entry points" {
    installed = testing.allocator;

    const block = allocate(64) orelse return error.AllocationFailed;
    try testing.expect(@intFromPtr(block) % payload_alignment.toByteUnits() == 0);

    const bytes: [*]u8 = @ptrCast(block);
    @memset(bytes[0..64], 0xAB);
    release(block);
}

test "zero and negative sizes are refused rather than passed on" {
    installed = testing.allocator;

    try testing.expect(allocate(0) == null);
    try testing.expect(allocate(-1) == null);
    // A null free is a no-op, as C requires.
    release(null);
}

test "calloc zeroes and realloc preserves" {
    installed = testing.allocator;

    const zeroed = allocateZeroed(32) orelse return error.AllocationFailed;
    const zeroed_bytes: [*]u8 = @ptrCast(zeroed);
    for (zeroed_bytes[0..32]) |byte| try testing.expectEqual(@as(u8, 0), byte);

    const written: [*]u8 = @ptrCast(zeroed);
    for (0..32) |i| written[i] = @intCast(i);

    const grown = reallocate(zeroed, 512) orelse return error.AllocationFailed;
    const grown_bytes: [*]u8 = @ptrCast(grown);
    for (0..32) |i| try testing.expectEqual(@as(u8, @intCast(i)), grown_bytes[i]);
    try testing.expect(@intFromPtr(grown) % payload_alignment.toByteUnits() == 0);

    const shrunk = reallocate(grown, 16) orelse return error.AllocationFailed;
    const shrunk_bytes: [*]u8 = @ptrCast(shrunk);
    for (0..16) |i| try testing.expectEqual(@as(u8, @intCast(i)), shrunk_bytes[i]);

    // A realloc to nothing frees, as flecs's own implementation does.
    try testing.expect(reallocate(shrunk, 0) == null);
}

test "realloc of a null block allocates" {
    installed = testing.allocator;

    const block = reallocate(null, 128) orelse return error.AllocationFailed;
    release(block);
}

test "a log handler receives what flecs would have printed" {
    const seen = struct {
        var level: LogLevel = .trace;
        var file: ?[:0]const u8 = null;
        var line: i32 = 0;
        var message: [:0]const u8 = "";
        var calls: usize = 0;

        fn handler(l: LogLevel, f: ?[:0]const u8, ln: i32, m: [:0]const u8) void {
            level = l;
            file = f;
            line = ln;
            message = m;
            calls += 1;
        }
    };

    setLogHandler(&seen.handler);
    defer setLogHandler(null);

    // Called through the field flecs itself calls, rather than through the thunk by
    // name: what is being checked is that the pointer flecs holds is the one that
    // reaches Zig, which is the half that can be wired up wrongly.
    const installed_log = core.ecs_os_api.log_ orelse return error.LogNotInstalled;
    installed_log(-2, "world.c", 42, "table not found");

    try testing.expectEqual(@as(usize, 1), seen.calls);
    try testing.expectEqual(LogLevel.warning, seen.level);
    try testing.expectEqualStrings("world.c", seen.file orelse return error.NoFile);
    try testing.expectEqual(@as(i32, 42), seen.line);
    try testing.expectEqualStrings("table not found", seen.message);
}

test "removing a handler puts flecs's own behaviour back, not a null pointer" {
    const noop = struct {
        fn log(_: LogLevel, _: ?[:0]const u8, _: i32, _: [:0]const u8) void {}
        fn abort() noreturn {
            unreachable;
        }
    };

    captureDefaults();
    const original_log = core.ecs_os_api.log_;
    const original_abort = core.ecs_os_api.abort_;

    setLogHandler(&noop.log);
    setAbortHandler(&noop.abort);
    try testing.expect(core.ecs_os_api.log_ != original_log);
    try testing.expect(core.ecs_os_api.abort_ != original_abort);

    setLogHandler(null);
    setAbortHandler(null);
    try testing.expectEqual(original_log, core.ecs_os_api.log_);
    try testing.expectEqual(original_abort, core.ecs_os_api.abort_);
    // flecs calls both without checking. Whatever they are, they are not null.
    try testing.expect(core.ecs_os_api.log_ != null);
    try testing.expect(core.ecs_os_api.abort_ != null);
}

test "the world count does not wrap when it is decremented past zero" {
    const before = worlds_alive.load(.monotonic);
    defer worlds_alive.store(before, .monotonic);

    worlds_alive.store(0, .monotonic);
    noteWorldDestroyed();
    try testing.expectEqual(@as(usize, 0), worlds_alive.load(.monotonic));

    noteWorldCreated();
    noteWorldCreated();
    try testing.expectEqual(@as(usize, 2), worlds_alive.load(.monotonic));

    noteWorldDestroyed();
    noteWorldDestroyed();
    noteWorldDestroyed();
    try testing.expectEqual(@as(usize, 0), worlds_alive.load(.monotonic));
}
