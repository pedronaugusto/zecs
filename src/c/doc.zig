//! flecs C declarations for documentation attached to entities.
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
pub const ecs_world_t = core.ecs_world_t;

/// Second element of the pair `ecs_doc_set_uuid` adds: `(EcsDocDescription, EcsDocUuid)`.
pub extern const EcsDocUuid: ecs_entity_t;

/// Second element of the pair `ecs_doc_set_brief` adds. flecs.h names this `EcsBrief` in
/// its doc comment, which is not a symbol that exists.
pub extern const EcsDocBrief: ecs_entity_t;

/// Second element of the pair `ecs_doc_set_detail` adds.
pub extern const EcsDocDetail: ecs_entity_t;

/// Second element of the pair `ecs_doc_set_link` adds.
pub extern const EcsDocLink: ecs_entity_t;

/// Second element of the pair `ecs_doc_set_color` adds.
pub extern const EcsDocColor: ecs_entity_t;

/// One piece of documentation, stored as the pair `(EcsDocDescription, kind)` where the
/// kind is `EcsName`, `EcsDocBrief`, `EcsDocDetail`, `EcsDocLink`, `EcsDocColor` or
/// `EcsDocUuid`. flecs copies the string in and owns it.
pub const EcsDocDescription = extern struct {
    value: ?[*:0]u8 = null,
};

/// Associate an entity with an external UUID. The `ecs_doc_set_*` operations all copy
/// the string, and a null value removes the doc pair instead of setting it.
pub extern fn ecs_doc_set_uuid(world: *ecs_world_t, entity: ecs_entity_t, uuid: ?[*:0]const u8) void;

/// Give an entity a human-readable name. Unlike an entity name it need not be unique and
/// may hold characters the query language reserves, such as `*`. Null removes it.
pub extern fn ecs_doc_set_name(world: *ecs_world_t, entity: ecs_entity_t, name: ?[*:0]const u8) void;

/// Give an entity a one-line description. Null removes it.
pub extern fn ecs_doc_set_brief(world: *ecs_world_t, entity: ecs_entity_t, description: ?[*:0]const u8) void;

/// Give an entity a long description. Null removes it.
pub extern fn ecs_doc_set_detail(world: *ecs_world_t, entity: ecs_entity_t, description: ?[*:0]const u8) void;

/// Give an entity a link to external documentation. Null removes it.
pub extern fn ecs_doc_set_link(world: *ecs_world_t, entity: ecs_entity_t, link: ?[*:0]const u8) void;

/// Give an entity a color, a hint for whatever visualizes the world. Null removes it.
pub extern fn ecs_doc_set_color(world: *ecs_world_t, entity: ecs_entity_t, color: ?[*:0]const u8) void;

/// The entity's UUID, null if it has none. Every `ecs_doc_get_*` result is owned by the
/// world and stays valid until that piece of documentation is changed or removed.
pub extern fn ecs_doc_get_uuid(world: *const ecs_world_t, entity: ecs_entity_t) ?[*:0]const u8;

/// The entity's human-readable name, falling back to its entity name when it has none.
/// To tell the two apart, test for the pair `(EcsDocDescription, EcsName)`.
pub extern fn ecs_doc_get_name(world: *const ecs_world_t, entity: ecs_entity_t) ?[*:0]const u8;

/// The entity's one-line description, null if it has none.
pub extern fn ecs_doc_get_brief(world: *const ecs_world_t, entity: ecs_entity_t) ?[*:0]const u8;

/// The entity's long description, null if it has none.
pub extern fn ecs_doc_get_detail(world: *const ecs_world_t, entity: ecs_entity_t) ?[*:0]const u8;

/// The entity's documentation link, null if it has none.
pub extern fn ecs_doc_get_link(world: *const ecs_world_t, entity: ecs_entity_t) ?[*:0]const u8;

/// The entity's color, null if it has none.
pub extern fn ecs_doc_get_color(world: *const ecs_world_t, entity: ecs_entity_t) ?[*:0]const u8;

/// Import the doc module, the equivalent of `ECS_IMPORT(world, FlecsDoc)` in C.
pub extern fn FlecsDocImport(world: *ecs_world_t) void;
