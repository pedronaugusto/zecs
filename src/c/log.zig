//! flecs C declarations for logging.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const core = @import("core.zig");

// Re-exported so a caller of this module sees one namespace rather than
// having to know which area a shared declaration came from.
pub const va_list = core.va_list;

/// Log that an operation is deprecated. Compiled away to nothing when the log addon is
/// off, which is why the ABI guard treats this name specially.
pub extern fn ecs_deprecated_(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Description for one of the `ECS_*` error codes. Static storage; do not free it.
pub extern fn ecs_strerror(error_code: i32) ?[*:0]const u8;

/// Indent subsequent log output by one level, making nested work legible. Pair it with
/// `ecs_log_pop_`.
pub extern fn ecs_log_push_(level: i32) void;

/// Undo one `ecs_log_push_`.
pub extern fn ecs_log_pop_(level: i32) void;

/// Whether a message at this level would be logged, for skipping the work of building
/// one that would be thrown away.
pub extern fn ecs_should_log(level: i32) bool;

/// Print at the provided log level.
pub extern fn ecs_print_(level: i32, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, ...) void;

/// Print at the provided log level (va_list).
pub extern fn ecs_printv_(level: c_int, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, args: va_list) void;

/// Log at the provided level.
pub extern fn ecs_log_(level: i32, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, ...) void;

/// Log at the provided level (va_list).
pub extern fn ecs_logv_(level: c_int, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, args: va_list) void;

/// Abort with error code.
pub extern fn ecs_abort_(error_code: i32, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, ...) void;

/// Log an assertion failure.
pub extern fn ecs_assert_log_(error_code: i32, condition_str: ?[*:0]const u8, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, ...) void;

/// Log a parser error.
pub extern fn ecs_parser_error_(name: ?[*:0]const u8, expr: ?[*:0]const u8, column: i64, fmt: ?[*:0]const u8, ...) void;

/// Log a parser error (va_list).
pub extern fn ecs_parser_errorv_(name: ?[*:0]const u8, expr: ?[*:0]const u8, column: i64, fmt: ?[*:0]const u8, args: va_list) void;

/// Log a parser warning.
pub extern fn ecs_parser_warning_(name: ?[*:0]const u8, expr: ?[*:0]const u8, column: i64, fmt: ?[*:0]const u8, ...) void;

/// Log a parser warning (va_list).
pub extern fn ecs_parser_warningv_(name: ?[*:0]const u8, expr: ?[*:0]const u8, column: i64, fmt: ?[*:0]const u8, args: va_list) void;

/// Set the log level and return the previous one. -1 silences warnings as well as
/// traces, -2 silences errors too.
///
/// Level 0 prints, among other things, the list of addons the library was actually
/// compiled with — which is the authoritative answer to that question, since addons
/// enable their own dependencies.
pub extern fn ecs_log_set_level(level: c_int) c_int;

/// Turn ANSI colors in log output on or off, returning the previous setting. They are
/// on by default.
pub extern fn ecs_log_enable_colors(enabled: bool) bool;

pub extern fn ecs_log_get_level() c_int;

/// Turn timestamps in log output on or off, returning the previous setting. Off by
/// default, because reading the clock on every log line is not free.
pub extern fn ecs_log_enable_timestamp(enabled: bool) bool;

/// Turn the "seconds since the last log line" prefix on or off, returning the previous
/// setting. Off by default, and costs a clock read per line like timestamps do.
pub extern fn ecs_log_enable_timedelta(enabled: bool) bool;

/// The last logged error code, 0 if none was logged since the last call. Reading it
/// resets it.
pub extern fn ecs_log_last_error() c_int;

/// Start capturing log output instead of writing it out. `capture_try` also captures
/// messages from `ecs_log_try` blocks.
pub extern fn ecs_log_start_capture(capture_try: bool) void;

/// Stop capturing and return what was captured, or null if nothing was. Free the result
/// with `ecs_os_free`.
pub extern fn ecs_log_stop_capture() ?[*:0]u8;
