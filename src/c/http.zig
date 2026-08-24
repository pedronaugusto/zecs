//! flecs C declarations for the HTTP server and the REST endpoint.
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
pub const ecs_http_reply_t = core.ecs_http_reply_t;
pub const ecs_http_request_t = core.ecs_http_request_t;
pub const ecs_http_server_desc_t = core.ecs_http_server_desc_t;
pub const ecs_http_server_t = core.ecs_http_server_t;
pub const ecs_size_t = core.ecs_size_t;
pub const ecs_world_t = core.ecs_world_t;

pub extern var ecs_http_request_received_count: i64;

pub extern var ecs_http_request_invalid_count: i64;

pub extern var ecs_http_request_handled_ok_count: i64;

pub extern var ecs_http_request_handled_error_count: i64;

pub extern var ecs_http_request_not_handled_count: i64;

pub extern var ecs_http_request_preflight_count: i64;

pub extern var ecs_http_send_ok_count: i64;

pub extern var ecs_http_send_error_count: i64;

pub extern var ecs_http_busy_count: i64;

/// Create a server. It is not listening yet; `ecs_http_server_start` does that. Null if
/// creation failed.
pub extern fn ecs_http_server_init(desc: *const ecs_http_server_desc_t) ?*ecs_http_server_t;

/// Destroy a server, stopping it first if it is still running.
pub extern fn ecs_http_server_fini(server: *ecs_http_server_t) void;

/// Stop accepting requests.
pub extern fn ecs_http_server_stop(server: *ecs_http_server_t) void;

/// Feed a request to the server directly, without a socket. `req` is a raw HTTP request
/// of `len` bytes — `GET /entity/flecs/core/World?label=true HTTP/1.1` and so on — and
/// need not be NUL-terminated unless `len` is 0, which asks flecs to measure it.
pub extern fn ecs_http_server_http_request(srv: *ecs_http_server_t, req: [*]const u8, len: ecs_size_t, reply_out: *ecs_http_reply_t) c_int;

/// Same as `ecs_http_server_http_request`, assembling the request line for you. `body`
/// is optional.
pub extern fn ecs_http_server_request(srv: *ecs_http_server_t, method: [*:0]const u8, req: [*:0]const u8, body: ?[*:0]const u8, reply_out: *ecs_http_reply_t) c_int;

/// The context from `ecs_http_server_desc_t.ctx`.
pub extern fn ecs_http_server_ctx(srv: *ecs_http_server_t) ?*anyopaque;

/// Find a header in a request by name. Null if the request has no such header. The
/// string belongs to the request and dies with it.
pub extern fn ecs_http_get_header(req: *const ecs_http_request_t, name: [*:0]const u8) ?[*:0]const u8;

/// Find a URL query parameter in a request by name, already percent-decoded. Null if
/// the request has no such parameter. The string belongs to the request.
pub extern fn ecs_http_get_param(req: *const ecs_http_request_t, name: [*:0]const u8) ?[*:0]const u8;

/// Import the REST module, the equivalent of `ECS_IMPORT(world, FlecsRest)` in C.
pub extern fn FlecsRestImport(world: *ecs_world_t) void;
