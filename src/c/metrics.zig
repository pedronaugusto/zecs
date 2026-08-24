//! flecs C declarations for metrics.
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
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_id_t = core.ecs_id_t;
pub const ecs_world_t = core.ecs_world_t;

pub extern var EcsMetric: ecs_entity_t;

pub extern var EcsCounter: ecs_entity_t;

pub extern var EcsCounterIncrement: ecs_entity_t;

pub extern var EcsCounterId: ecs_entity_t;

pub extern var EcsGauge: ecs_entity_t;

pub extern var EcsMetricInstance: ecs_entity_t;

/// Value of a metric instance.
pub const EcsMetricValue = extern struct {
    value: f64 = 0,
};

/// The entity a metric instance was measured from.
pub const EcsMetricSource = extern struct {
    entity: ecs_entity_t = 0,
};

pub const ecs_metric_desc_t = extern struct {
    /// Validity check. Do not set.
    _canary: i32 = 0,
    entity: ecs_entity_t = 0,
    /// Member holding the measured value. Mutually exclusive with `id`, and not usable
    /// with `EcsCounterId`.
    member: ecs_entity_t = 0,
    /// Dotted member path, for nested members. Set it together with `id` and instead of
    /// `member`.
    dotmember: ?[*:0]const u8 = null,
    /// Component whose presence is measured. Mutually exclusive with `member`.
    id: ecs_id_t = 0,
    /// For an `(R, *)` id, measure each target separately rather than the pair as a
    /// whole. Needs `R` to have the `OneOf` property unless the kind is `EcsCounterId`.
    targets: bool = false,
    /// `EcsGauge`, `EcsCounter`, `EcsCounterIncrement` or `EcsCounterId`.
    kind: ecs_entity_t = 0,
    /// Only stored when the doc addon is enabled.
    brief: ?[*:0]const u8 = null,
};

/// Create a metric: an entity that samples something out of the storage — a member
/// value, how long an entity has had a component, how many entities have one — behind
/// one interface a monitor or a debugger can discover. A gauge reads the value now; the
/// three counter kinds accumulate. `EcsCounter` stores the member as-is,
/// `EcsCounterIncrement` adds `member * delta_time` each frame, and `EcsCounterId`
/// counts entities holding an id.
pub extern fn ecs_metric_init(world: *ecs_world_t, desc: *const ecs_metric_desc_t) ecs_entity_t;

/// Import the metrics module, the equivalent of `ECS_IMPORT(world, FlecsMetrics)` in C.
pub extern fn FlecsMetricsImport(world: *ecs_world_t) void;
