//! flecs C declarations for systems.
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
pub const ecs_ctx_free_t = core.ecs_ctx_free_t;
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_ftime_t = core.ecs_ftime_t;
pub const ecs_header_t = core.ecs_header_t;
pub const ecs_iter_action_t = core.ecs_iter_action_t;
pub const ecs_observer_desc_t = core.ecs_observer_desc_t;
pub const ecs_query_t = core.ecs_query_t;
pub const ecs_run_action_t = core.ecs_run_action_t;
pub const ecs_system_desc_t = core.ecs_system_desc_t;
pub const ecs_world_t = core.ecs_world_t;
pub const flecs_poly_dtor_t = core.flecs_poly_dtor_t;

/// Tick source component, added by the timer operations. `tick` is true on the frames
/// the source fires; `time_elapsed` is the time since the previous tick.
pub const EcsTickSource = extern struct {
    tick: bool = false,
    time_elapsed: ecs_ftime_t = 0,
};

pub extern fn ecs_system_init(world: *ecs_world_t, desc: *const ecs_system_desc_t) ecs_entity_t;

pub extern fn ecs_run(world: *ecs_world_t, system: ecs_entity_t, delta_time: ecs_ftime_t, param: ?*anyopaque) ecs_entity_t;

pub extern fn ecs_observer_init(world: *ecs_world_t, desc: *const ecs_observer_desc_t) ecs_entity_t;

/// Reconfigure a system created with `ecs_system_init`. Only fields of `desc` set to a
/// non-default value are applied; the rest keep their current value.
pub extern fn ecs_system_update(world: *ecs_world_t, system: ecs_entity_t, desc: *const ecs_system_desc_t) ecs_entity_t;

pub const ecs_system_t = extern struct {
    hdr: ecs_header_t = .{},
    run: ecs_run_action_t = null,
    action: ecs_iter_action_t = null,
    query: ?*ecs_query_t = null,
    group_id: u64 = 0,
    group_id_set: bool = false,
    tick_source: ecs_entity_t = 0,
    multi_threaded: bool = false,
    immediate: bool = false,
    name: ?[*:0]const u8 = null,
    ctx: ?*anyopaque = null,
    callback_ctx: ?*anyopaque = null,
    run_ctx: ?*anyopaque = null,
    ctx_free: ecs_ctx_free_t = null,
    callback_ctx_free: ecs_ctx_free_t = null,
    run_ctx_free: ecs_ctx_free_t = null,
    time_spent: ecs_ftime_t = 0,
    time_passed: ecs_ftime_t = 0,
    last_frame: i64 = 0,
    dtor: flecs_poly_dtor_t = null,
};

/// Get an entity's system, for reading its query and context. Null when the entity is
/// not a system.
pub extern fn ecs_system_get(world: *const ecs_world_t, system: ecs_entity_t) ?*const ecs_system_t;

/// Restrict a system built on a grouped query to one group. Applies to manual runs and
/// to pipeline execution alike.
pub extern fn ecs_system_set_group(world: *ecs_world_t, system: ecs_entity_t, group_id: u64) void;

/// Same as `ecs_run`, over this worker's share of the matched entities.
pub extern fn ecs_run_worker(world: *ecs_world_t, system: ecs_entity_t, stage_current: i32, stage_count: i32, delta_time: ecs_ftime_t, param: ?*anyopaque) ecs_entity_t;

/// Import the system module, the equivalent of `ECS_IMPORT(world, FlecsSystem)` in C.
pub extern fn FlecsSystemImport(world: *ecs_world_t) void;
