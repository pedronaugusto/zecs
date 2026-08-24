//! flecs C declarations for alerts.
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
pub const ecs_ftime_t = core.ecs_ftime_t;
pub const ecs_id_t = core.ecs_id_t;
pub const ecs_query_desc_t = core.ecs_query_desc_t;
pub const ecs_world_t = core.ecs_world_t;

pub extern var EcsAlertInfo: ecs_entity_t;

pub extern var EcsAlertWarning: ecs_entity_t;

pub extern var EcsAlertError: ecs_entity_t;

pub extern var EcsAlertCritical: ecs_entity_t;

/// The generated message of an alert instance. Owned by flecs.
pub const EcsAlertInstance = extern struct {
    message: ?[*:0]u8 = null,
};

/// Added to an entity while it has active alerts, removed once the last one clears.
/// flecs defines this type, but it holds an `ecs_map_t`, which this file keeps opaque.
pub const EcsAlertsActive = opaque {};

/// Raises an alert's severity for entities that also match `with`, so that one alert
/// covers several severities and an entity can move between them without resetting how
/// long the alert has been active.
pub const ecs_alert_severity_filter_t = extern struct {
    severity: ecs_entity_t = 0,
    with: ecs_id_t = 0,
    /// Query variable to match `with` on, written without the `$`. Null means `$this`.
    @"var": ?[*:0]const u8 = null,
    /// Resolved index of `var`. Do not set.
    _var_index: i32 = 0,
};

pub const ecs_alert_desc_t = extern struct {
    /// Validity check. Do not set.
    _canary: i32 = 0,
    entity: ecs_entity_t = 0,
    /// The query the alert watches. At least one term must use `$this`.
    query: ecs_query_desc_t = .{},
    /// Message template, interpolated by `ecs_script_string_interpolate`, so it can name
    /// query variables: `"$this has Position but not Velocity"`.
    message: ?[*:0]const u8 = null,
    /// Only stored when the doc addon is enabled.
    doc_name: ?[*:0]const u8 = null,
    /// Only stored when the doc addon is enabled.
    brief: ?[*:0]const u8 = null,
    /// `EcsAlertInfo`, `EcsAlertWarning`, `EcsAlertError` or `EcsAlertCritical`.
    /// Defaults to `EcsAlertError`.
    severity: ecs_entity_t = 0,
    severity_filters: [4]ecs_alert_severity_filter_t = @splat(.{}),
    /// How long an alert stays after it stops matching, which keeps a noisy alert from
    /// flickering. Its duration stops growing while it is inactive. 0 clears at once.
    retain_period: ecs_ftime_t = 0,
    /// Alert when this member leaves the ranges in its `EcsMemberRanges` component.
    member: ecs_entity_t = 0,
    /// Component holding `member`. Defaults to the member's parent entity.
    id: ecs_id_t = 0,
    /// Query variable to read `id` from, written without the `$`. Null means `$this`.
    @"var": ?[*:0]const u8 = null,
};

/// Create an alert: a query evaluated periodically that raises one alert instance per
/// matching entity, and clears it when the query stops matching. Instances are children
/// of the alert and carry `EcsAlertInstance` with the message, `EcsMetricSource` with
/// the entity, and `EcsMetricValue` with how long the alert has been active — the
/// metrics components, so alerts show up in whatever discovers metrics.
pub extern fn ecs_alert_init(world: *ecs_world_t, desc: *const ecs_alert_desc_t) ecs_entity_t;

/// How many alerts are active for an entity. With `alert` set, whether that one alert is
/// active; with `alert` 0, the total across all of them.
pub extern fn ecs_get_alert_count(world: *const ecs_world_t, entity: ecs_entity_t, alert: ecs_entity_t) i32;

/// The alert instance an entity has for an alert, 0 when the alert is not active for it.
pub extern fn ecs_get_alert(world: *const ecs_world_t, entity: ecs_entity_t, alert: ecs_entity_t) ecs_entity_t;

/// Import the alerts module, the equivalent of `ECS_IMPORT(world, FlecsAlerts)` in C.
pub extern fn FlecsAlertsImport(world: *ecs_world_t) void;
