//! Routes flecs's allocations through a `std.mem.Allocator`.
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
const c = @import("c.zig");
const options = @import("zecs_options");
const Error = @import("error.zig").Error;

//=============================================================================
// Block layout
//=============================================================================

/// Alignment handed to flecs. C's `malloc` guarantees this much, flecs assumes it for
/// component storage, and nothing in flecs ever asks for more.
const payload_alignment: std.mem.Alignment = .@"16";

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
/// raw C API are invisible here, which is why the allocation counters are consulted too.
var worlds_alive: usize = 0;

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
    if (worlds_alive != 0) return Error.WorldAlreadyExists;

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
    worlds_alive += 1;
}

pub fn noteWorldDestroyed() void {
    if (worlds_alive != 0) worlds_alive -= 1;
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
