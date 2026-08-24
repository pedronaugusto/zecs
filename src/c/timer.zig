//! flecs C declarations for timers and rate filters.
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
pub const ecs_world_t = core.ecs_world_t;

/// One-shot and interval timer component.
pub const EcsTimer = extern struct {
    timeout: ecs_ftime_t = 0,
    time: ecs_ftime_t = 0,
    /// Correction carried over when a frame overshoots the timeout.
    overshoot: ecs_ftime_t = 0,
    fired_count: i32 = 0,
    active: bool = false,
    single_shot: bool = false,
};

/// Rate filter component: ticks once every `rate` ticks of `src`.
pub const EcsRateFilter = extern struct {
    src: ecs_entity_t = 0,
    rate: i32 = 0,
    tick_count: i32 = 0,
    time_elapsed: ecs_ftime_t = 0,
};

/// Fire the entity once, `timeout` seconds from now, and make it a tick source. An
/// existing timer on the entity is reset. Time is advanced by `delta_time` each frame,
/// so this is synchronous with the main loop. When the entity is a system, the system
/// runs on the tick; otherwise read `EcsTickSource.tick`. Start and stop it with
/// `ecs_start_timer` and `ecs_stop_timer`.
pub extern fn ecs_set_timeout(world: *ecs_world_t, tick_source: ecs_entity_t, timeout: ecs_ftime_t) ecs_entity_t;

/// The timeout set by `ecs_set_timeout`. 0 when the entity has no timer — which includes
/// after the timeout fired, because that removes the `EcsTimer` component.
pub extern fn ecs_get_timeout(world: *const ecs_world_t, tick_source: ecs_entity_t) ecs_ftime_t;

/// Fire the entity every `interval` seconds and make it a tick source, otherwise like
/// `ecs_set_timeout`. An existing timer on the entity is reset.
pub extern fn ecs_set_interval(world: *ecs_world_t, tick_source: ecs_entity_t, interval: ecs_ftime_t) ecs_entity_t;

/// The interval set by `ecs_set_interval`. 0 when the entity is not a timer.
pub extern fn ecs_get_interval(world: *const ecs_world_t, tick_source: ecs_entity_t) ecs_ftime_t;

/// Reset a timer to 0 and start it.
pub extern fn ecs_start_timer(world: *ecs_world_t, tick_source: ecs_entity_t) void;

/// Stop a timer from firing, keeping its current time value.
pub extern fn ecs_stop_timer(world: *ecs_world_t, tick_source: ecs_entity_t) void;

/// Reset a timer's time value to 0 without stopping it.
pub extern fn ecs_reset_timer(world: *ecs_world_t, tick_source: ecs_entity_t) void;

/// Start new timers at a random point in their period, so that timers sharing an
/// interval do not all land on the same frame.
pub extern fn ecs_randomize_timers(world: *ecs_world_t) void;

/// Make the entity tick once every `rate` ticks of `source`, and a tick source itself,
/// so rate filters chain. With `source` 0 the frame tick is used, which counts calls to
/// `ecs_progress`. Unlike two interval timers, whose ratio drifts with floating-point
/// rounding, a rate filter ticks at an exact multiple of its source.
pub extern fn ecs_set_rate(world: *ecs_world_t, tick_source: ecs_entity_t, rate: i32, source: ecs_entity_t) ecs_entity_t;

/// Drive a system from a shared tick source. Two systems given the same interval or rate
/// can drift apart — disabling one is enough to do it — while two systems sharing a tick
/// source are guaranteed to run on the same frame.
pub extern fn ecs_set_tick_source(world: *ecs_world_t, system: ecs_entity_t, tick_source: ecs_entity_t) void;

/// Import the timer module, the equivalent of `ECS_IMPORT(world, FlecsTimer)` in C.
pub extern fn FlecsTimerImport(world: *ecs_world_t) void;
