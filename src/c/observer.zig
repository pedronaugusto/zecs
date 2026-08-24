//! flecs C declarations for observers.
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
pub const ecs_event_desc_t = core.ecs_event_desc_t;
pub const ecs_observer_desc_t = core.ecs_observer_desc_t;
pub const ecs_observer_t = core.ecs_observer_t;
pub const ecs_world_t = core.ecs_world_t;

pub const ecs_event_id_record_t = opaque {};

/// Send an event, the mechanism flecs itself uses for `OnAdd`, `OnRemove` and the rest.
/// Any entity works as a custom event; do not send the built-in ones, which observers
/// assume are only sent under conditions flecs controls. Observers run synchronously, so
/// `desc.param` may point at stack data.
pub extern fn ecs_emit(world: *ecs_world_t, desc: *ecs_event_desc_t) void;

/// Enqueue an event, to be emitted when `ecs_defer_end` is called. On a world that is
/// not deferred this behaves exactly like `ecs_emit`.
pub extern fn ecs_enqueue(world: *ecs_world_t, desc: *ecs_event_desc_t) void;

/// Reconfigure an observer created with `ecs_observer_init`. Only fields of `desc` set
/// to a non-default value are applied; the rest keep their current value. The `query`
/// and `events` fields are ignored — neither can change after creation. Returns the
/// observer, or 0 on failure.
pub extern fn ecs_observer_update(world: *ecs_world_t, observer: ecs_entity_t, desc: *const ecs_observer_desc_t) ecs_entity_t;

/// Get an entity's observer, for reading its query and context. Null when the entity is
/// not an observer.
pub extern fn ecs_observer_get(world: *const ecs_world_t, observer: ecs_entity_t) ?*const ecs_observer_t;
