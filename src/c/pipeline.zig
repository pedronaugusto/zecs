//! flecs C declarations for pipelines.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const alerts = @import("alerts.zig");
const core = @import("core.zig");
const entity = @import("entity.zig");
const metrics = @import("metrics.zig");
const timer = @import("timer.zig");
const world = @import("world.zig");

// Re-exported so a caller of this module sees one namespace rather than
// having to know which area a shared declaration came from.
pub const FlecsAlertsImport = alerts.FlecsAlertsImport;
pub const FlecsStatsImport = core.FlecsStatsImport;
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_ftime_t = core.ecs_ftime_t;
pub const ecs_query_desc_t = core.ecs_query_desc_t;
pub const ecs_world_t = core.ecs_world_t;
pub const ecs_set_scope = entity.ecs_set_scope;
pub const FlecsMetricsImport = metrics.FlecsMetricsImport;
pub const ecs_set_interval = timer.ecs_set_interval;
pub const ecs_import = world.ecs_import;
pub const ecs_module_init = world.ecs_module_init;

pub const ecs_pipeline_desc_t = extern struct {
    entity: ecs_entity_t = 0,
    query: ecs_query_desc_t = .{},
};

/// Create a custom pipeline. 0 if the descriptor is invalid. If `desc.entity` names an
/// existing entity it must not already hold a pipeline; `ecs_pipeline_update` replaces
/// one.
pub extern fn ecs_pipeline_init(world: *ecs_world_t, desc: *const ecs_pipeline_desc_t) ecs_entity_t;

/// Replace the pipeline held by an entity, building a new one from the descriptor.
pub extern fn ecs_pipeline_update(world: *ecs_world_t, pipeline: ecs_entity_t, desc: *const ecs_pipeline_desc_t) ecs_entity_t;

/// Set the pipeline `ecs_progress` runs.
pub extern fn ecs_set_pipeline(world: *ecs_world_t, pipeline: ecs_entity_t) void;

/// Scale simulation speed by a multiplier, which `ecs_progress` applies to `delta_time`.
pub extern fn ecs_set_time_scale(world: *ecs_world_t, scale: ecs_ftime_t) void;

/// Reset the clock that tracks total simulation time.
pub extern fn ecs_reset_clock(world: *ecs_world_t) void;

/// Run every system in a pipeline. Callable from several threads, but only while staging
/// is off: the pipeline owns staging and the synchronization between threads.
pub extern fn ecs_run_pipeline(world: *ecs_world_t, pipeline: ecs_entity_t, delta_time: ecs_ftime_t) void;

/// Whether the world was asked for task threads rather than long-lived worker threads.
pub extern fn ecs_using_task_threads(world: *ecs_world_t) bool;

/// Import the pipeline module, the equivalent of `ECS_IMPORT(world, FlecsPipeline)` in C.
pub extern fn FlecsPipelineImport(world: *ecs_world_t) void;
