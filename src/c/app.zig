//! flecs C declarations for the app addon.
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
pub const ecs_app_desc_t = core.ecs_app_desc_t;
pub const ecs_world_t = core.ecs_world_t;

pub const ecs_app_run_action_t = ?*const fn (world: *ecs_world_t, desc: *ecs_app_desc_t) callconv(.c) c_int;

pub const ecs_app_frame_action_t = ?*const fn (world: *ecs_world_t, desc: *const ecs_app_desc_t) callconv(.c) c_int;

/// Run a single frame, the default frame action. Calls `ecs_progress` unless a custom
/// frame action was set, and returns what it returned.
pub extern fn ecs_app_run_frame(world: *ecs_world_t, desc: *const ecs_app_desc_t) c_int;

/// Replace the loop `ecs_app_run` runs. Process-wide, not per world.
pub extern fn ecs_app_set_run_action(callback: ecs_app_run_action_t) c_int;

/// Replace what `ecs_app_run_frame` does. Process-wide, not per world.
pub extern fn ecs_app_set_frame_action(callback: ecs_app_frame_action_t) c_int;
