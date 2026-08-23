//! The app loop, and the REST interface the flecs Explorer connects to.
//!
//! `run` is flecs's own main loop: it applies a few world settings, optionally starts a
//! REST server, and then calls `progress` until something asks it to stop. It is a
//! convenience, not a requirement — `while (world.progress(0)) {}` is the same loop
//! without the descriptor.
//!
//! What is not wrapped, and why:
//!
//! - `ecs_app_run_frame` runs one frame and returns *zero to keep going*, which is the
//!   opposite of `World.progress`. Inverting it would be a wrapper that adds a negation
//!   and no type information, so the raw call is the binding — and the inversion is
//!   written down here rather than discovered.
//! - `ecs_app_set_run_action` and `ecs_app_set_frame_action` replace the loop for the
//!   whole process, not for one world, and refuse a second, different callback with
//!   -1. A thunk would hand the callback the same raw world and the same raw
//!   descriptor it gets today, so there is nothing to type.
//! - The HTTP server — `ecs_http_server_init`, `start`, `stop`, `dequeue`, the request
//!   and reply structs, the header and parameter lookups. It is a C server API with a C
//!   reply callback, serving requests flecs itself does not define; a Zig program that
//!   wants an HTTP server has `std.http`. What REST needs of it is wrapped below, and
//!   the rest is `zecs.c`.

const std = @import("std");
const c = @import("c.zig");
const options = @import("zecs_options");
const component_mod = @import("component.zig");
const world_mod = @import("world.zig");
const Error = @import("error.zig").Error;

const Component = component_mod.Component;
const World = world_mod.World;

//=============================================================================
// The app loop
//=============================================================================

/// How `run` should drive the world.
pub const AppDesc = struct {
    /// Sleep between frames to hold this frame rate. Zero runs as fast as it can.
    target_fps: c.ecs_ftime_t = 0,

    /// The delta time handed to each frame. Zero asks flecs to measure it.
    delta_time: c.ecs_ftime_t = 0,

    /// Worker threads, as `World.setThreads`.
    threads: i32 = 0,

    /// Frames to run before returning. Zero runs until `World.quit`.
    frames: i32 = 0,

    /// Start a REST server so the Explorer can attach. Needs the rest addon; without
    /// it flecs logs a warning and carries on.
    enable_rest: bool = false,

    /// Import the stats module, so the world samples itself every frame. Needs the
    /// stats addon; same warning if it is missing.
    enable_stats: bool = false,

    /// Port for the REST server. Zero is flecs's default, 27750, which is where the
    /// Explorer looks.
    port: u16 = 0,

    /// Run once, before the first frame. Build one with `zecs.app.initAction`.
    init: c.ecs_app_init_action_t = null,

    /// Reserved by flecs for custom run and frame actions.
    ctx: ?*anyopaque = null,

    /// Fills in a C descriptor, for the fields this wrapper does not cover.
    pub fn toC(self: AppDesc) c.ecs_app_desc_t {
        return .{
            .target_fps = self.target_fps,
            .delta_time = self.delta_time,
            .threads = self.threads,
            .frames = self.frames,
            .enable_rest = self.enable_rest,
            .enable_stats = self.enable_stats,
            .port = self.port,
            .init = self.init,
            .ctx = self.ctx,
        };
    }
};

/// Turns a Zig function into the C callback `AppDesc.init` stores.
///
/// The thunk is generated at compile time, so this produces the same code as writing
/// the C-ABI function by hand. flecs ignores the value the callback returns, so the
/// handler returns nothing.
///
/// ```zig
/// fn setUp(world: zecs.World) void { ... }
/// ...
/// try zecs.app.run(world, .{ .frames = 60, .init = zecs.app.initAction(setUp) });
/// ```
pub fn initAction(comptime handler: fn (world: World) void) c.ecs_app_init_action_t {
    return &struct {
        fn thunk(raw: *c.ecs_world_t) callconv(.c) c_int {
            handler(.{ .raw = raw });
            return 0;
        }
    }.thunk;
}

/// Runs the world until it quits, or until `desc.frames` frames have passed.
///
/// The world is still yours afterwards. flecs's header says it is cleaned up, and it
/// is not: the default run action calls `ecs_quit`, which sets the quit flag and
/// nothing more. Keep the `defer world.deinit()` — and note that a world that has quit
/// stays quit, so `World.progress` returns false from then on.
///
/// Needs the app addon.
pub fn run(world: World, desc: AppDesc) Error!void {
    if (comptime !options.addon_app) @compileError(
        "zecs.app.run needs the app addon: build with -Daddon_app=true",
    );

    // flecs copies the descriptor into a process-wide slot and passes the copy to the
    // run action, so the caller's value does not have to outlive the call.
    var c_desc = desc.toC();
    if (c.ecs_app_run(world.raw, &c_desc) != 0) return Error.AppRunFailed;
}

//=============================================================================
// REST
//=============================================================================

/// What to set on a world to start a REST server.
pub const Rest = struct {
    /// Zero is flecs's default, 27750.
    port: u16 = 0,
    /// The address to bind to. All interfaces when left null.
    ipaddr: ?[:0]const u8 = null,
};

/// The `EcsRest` component, typed, so the ordinary `World.get` and `World.set` reach
/// it: `world.get(zecs.c.EcsWorld, zecs.app.restComponent())`.
///
/// Zero until the rest module has been imported, which `World.init` does and
/// `World.initMinimal` does not.
pub inline fn restComponent() Component(c.EcsRest) {
    return .{ .id = c.FLECS_IDEcsRestID_ };
}

/// Starts a REST server on the world, so the flecs Explorer can attach to it.
///
/// The short version, and the one to reach for: setting the component makes flecs own
/// the server. It creates one and starts it listening immediately, from the
/// component's `OnSet` hook, and its module installs a system on `PostFrame` that
/// services requests — so requests are only answered while something is calling
/// `World.progress`. The server is torn down with the world.
///
/// There is nothing to return: flecs reports a server it could not start through its
/// logger and carries on. `RestServer.init` is the version that says so.
///
/// flecs copies `ipaddr`, so the string does not have to outlive the call.
///
/// Needs the rest addon.
pub fn enableRest(world: World, desc: Rest) void {
    if (comptime !options.addon_rest) @compileError(
        "zecs.app.enableRest needs the rest addon: build with -Daddon_rest=true",
    );

    world.set(c.EcsWorld, restComponent(), .{
        .port = desc.port,
        // `EcsRest.ipaddr` is a mutable C string because flecs frees its own copy of
        // it. The copy is made by the component's copy hook, on the way in.
        .ipaddr = if (desc.ipaddr) |a| @constCast(a.ptr) else null,
        .impl = null,
    });
}

/// How to start a REST server that is not attached to a world's component.
///
/// `ecs_http_server_desc_t` also has a `callback` and a `ctx`, and
/// `ecs_rest_server_init` overwrites both with its own reply handler — so they are
/// left out here rather than offered and silently discarded.
pub const RestServerDesc = struct {
    /// Zero is flecs's default, 27750.
    port: u16 = 0,
    /// The address to bind to. All interfaces when left null.
    ipaddr: ?[:0]const u8 = null,
    /// How long the send queue waits between flushes, in milliseconds.
    send_queue_wait_ms: i32 = 0,
    /// How long a cached reply stays fresh, in seconds.
    cache_timeout: f64 = 0,
    /// How long a stale cached reply is kept before it is dropped, in seconds.
    cache_purge_timeout: f64 = 0,

    /// Fills in a C descriptor, for the fields this wrapper does not cover.
    pub fn toC(self: RestServerDesc) c.ecs_http_server_desc_t {
        return .{
            .port = self.port,
            .ipaddr = if (self.ipaddr) |a| a.ptr else null,
            .send_queue_wait_ms = self.send_queue_wait_ms,
            .cache_timeout = self.cache_timeout,
            .cache_purge_timeout = self.cache_purge_timeout,
        };
    }
};

/// A REST server the caller owns, rather than one the world owns.
///
/// Use this when the server's lifetime is not the world's. Otherwise `enableRest` is
/// less to get wrong — it does all three of the steps below.
///
/// Creating one does not open a port and does not answer anything. Two raw calls
/// finish the job, and they stay raw because each is one line that adds no type:
/// `zecs.c.ecs_http_server_start(server.raw)` spawns the threads that listen, and
/// needs the OS API implementation addon for them; and
/// `zecs.c.ecs_http_server_dequeue(server.raw, delta_time)` has to be called every
/// frame, because a started server queues requests and replies to none until it is.
pub const RestServer = struct {
    raw: *c.ecs_http_server_t,

    /// Creates a server. Not listening yet — see above.
    ///
    /// Needs the rest addon.
    pub fn init(world: World, desc: RestServerDesc) Error!RestServer {
        if (comptime !options.addon_rest) @compileError(
            "zecs.app.RestServer needs the rest addon: build with -Daddon_rest=true",
        );

        const c_desc = desc.toC();
        const raw = c.ecs_rest_server_init(world.raw, &c_desc) orelse
            return Error.RestServerInitFailed;
        return .{ .raw = raw };
    }

    /// Stops the server if it was started, and frees it. Must not be used on a server
    /// flecs owns through the `EcsRest` component.
    pub fn deinit(self: RestServer) void {
        c.ecs_rest_server_fini(self.raw);
    }
};

//=============================================================================
// Tests
//=============================================================================

test "an app descriptor carries every field flecs reads" {
    const desc = AppDesc{
        .target_fps = 60,
        .delta_time = 0.25,
        .threads = 2,
        .frames = 7,
        .enable_rest = true,
        .enable_stats = true,
        .port = 1234,
    };
    const c_desc = desc.toC();

    try std.testing.expectEqual(@as(c.ecs_ftime_t, 60), c_desc.target_fps);
    try std.testing.expectEqual(@as(c.ecs_ftime_t, 0.25), c_desc.delta_time);
    try std.testing.expectEqual(@as(i32, 2), c_desc.threads);
    try std.testing.expectEqual(@as(i32, 7), c_desc.frames);
    try std.testing.expect(c_desc.enable_rest);
    try std.testing.expect(c_desc.enable_stats);
    try std.testing.expectEqual(@as(u16, 1234), c_desc.port);
    try std.testing.expectEqual(@as(c.ecs_app_init_action_t, null), c_desc.init);
}

test "a default app descriptor asks flecs for its own defaults" {
    // Every field of `ecs_app_desc_t` treats zero as "decide for me": measure the frame
    // time, run until quit, no threads, no REST, flecs's own port.
    const built = (AppDesc{}).toC();
    inline for (@typeInfo(c.ecs_app_desc_t).@"struct".fields) |field| {
        const value = @field(built, field.name);
        switch (@typeInfo(field.type)) {
            .optional, .pointer => try std.testing.expect(value == null),
            .bool => try std.testing.expect(!value),
            else => try std.testing.expectEqual(@as(field.type, 0), value),
        }
    }
}

test "a REST descriptor leaves the callback flecs overwrites alone" {
    const desc = RestServerDesc{ .port = 27750, .ipaddr = "127.0.0.1", .cache_timeout = 0.2 };
    const c_desc = desc.toC();

    try std.testing.expectEqual(@as(u16, 27750), c_desc.port);
    try std.testing.expectEqualStrings("127.0.0.1", std.mem.span(c_desc.ipaddr.?));
    try std.testing.expectEqual(@as(f64, 0.2), c_desc.cache_timeout);
    try std.testing.expectEqual(@as(c.ecs_http_reply_action_t, null), c_desc.callback);
    try std.testing.expectEqual(@as(?*anyopaque, null), c_desc.ctx);
}
