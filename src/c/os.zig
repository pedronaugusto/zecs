//! flecs C declarations for the OS abstraction flecs calls out through.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const core = @import("core.zig");

// Re-exported so a caller of this module sees one namespace rather than
// having to know which area a shared declaration came from. Types only: the
// table itself, `core.ecs_os_api`, is a linked symbol, and a `pub const` alias
// of one is a compile-time constant standing where the ABI guard expects an
// `extern` — which it says so, at some length. Import `c/core.zig` for it.
pub const ecs_os_api_abort_t = core.ecs_os_api_abort_t;
pub const ecs_os_api_log_t = core.ecs_os_api_log_t;
pub const ecs_os_api_malloc_t = core.ecs_os_api_malloc_t;
pub const ecs_os_api_perf_trace_t = core.ecs_os_api_perf_trace_t;
pub const ecs_os_api_t = core.ecs_os_api_t;
pub const ecs_os_mutex_t = core.ecs_os_mutex_t;
pub const ecs_os_thread_callback_t = core.ecs_os_thread_callback_t;
pub const ecs_os_thread_t = core.ecs_os_thread_t;
pub const ecs_size_t = core.ecs_size_t;
pub const ecs_time_t = core.ecs_time_t;

/// Allocation counters maintained by flecs's own OS API implementation. They stop
/// moving once those callbacks are replaced, which is precisely what makes them useful
/// as evidence that flecs has already allocated through someone else's allocator.
pub extern var ecs_os_api_malloc_count: i64;

pub extern var ecs_os_api_realloc_count: i64;

pub extern var ecs_os_api_calloc_count: i64;

pub extern var ecs_os_api_free_count: i64;

pub const ecs_os_api_task_new_t = ?*const fn (callback: ecs_os_thread_callback_t, param: ?*anyopaque) callconv(.c) ecs_os_thread_t;

pub const ecs_os_api_task_join_t = ?*const fn (thread: ecs_os_thread_t) callconv(.c) ?*anyopaque;

pub const ecs_os_api_mutex_unlock_t = ?*const fn (mutex: ecs_os_mutex_t) callconv(.c) void;

pub const ecs_os_api_enable_high_timer_resolution_t = ?*const fn (enable: bool) callconv(.c) void;

pub extern fn ecs_os_init() void;

pub extern fn ecs_os_fini() void;

pub extern fn ecs_os_set_api(os_api: *const ecs_os_api_t) void;

pub extern fn ecs_os_get_api() ecs_os_api_t;

pub extern fn ecs_os_set_api_defaults() void;

pub extern fn ecs_os_has_heap() bool;

pub extern fn ecs_os_has_threading() bool;

pub extern fn ecs_os_has_task_support() bool;

pub extern fn ecs_os_has_time() bool;

pub extern fn ecs_os_has_logging() bool;

pub extern fn ecs_os_has_dl() bool;

pub extern fn ecs_os_has_modules() bool;

/// Log at debug level.
pub extern fn ecs_os_dbg(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Log at trace level.
pub extern fn ecs_os_trace(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Log at warning level.
pub extern fn ecs_os_warn(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Log at error level.
pub extern fn ecs_os_err(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Log at fatal level.
pub extern fn ecs_os_fatal(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Convert errno to a string. Static storage owned by the C library, not a copy.
pub extern fn ecs_os_strerror(err: c_int) [*:0]const u8;

/// Free whatever `str` points at and put a fresh copy of `value` there. `str` is one
/// string variable, not an array.
pub extern fn ecs_os_strset(str: *?[*:0]u8, value: ?[*:0]const u8) void;

/// Push a performance trace region.
pub extern fn ecs_os_perf_trace_push_(file: ?[*:0]const u8, line: usize, name: ?[*:0]const u8) void;

/// Pop a performance trace region.
pub extern fn ecs_os_perf_trace_pop_(file: ?[*:0]const u8, line: usize, name: ?[*:0]const u8) void;

/// Sleep with floating-point time.
pub extern fn ecs_sleepf(t: f64) void;

/// Seconds elapsed since `start`, which is then overwritten with the current time. Pass
/// a zeroed value to get the seconds since the epoch instead.
pub extern fn ecs_time_measure(start: *ecs_time_t) f64;

/// Calculate the difference between two timestamps.
pub extern fn ecs_time_sub(t1: ecs_time_t, t2: ecs_time_t) ecs_time_t;

/// Convert a time value to a double.
pub extern fn ecs_time_to_double(t: ecs_time_t) f64;

/// Return newly allocated memory that contains a copy of src.
pub extern fn ecs_os_memdup(src: ?*const anyopaque, size: ecs_size_t) ?*anyopaque;

/// Install the platform's default OS API: allocation, threading, timing, and the rest of
/// `ecs_os_api_t`. flecs calls this itself unless the build turned it off, so the reason
/// to call it by hand is to reinstate the defaults after overriding some of them.
pub extern fn ecs_set_os_api_impl() void;
