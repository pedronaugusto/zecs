//! flecs C declarations for JSON serialisation.
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
pub const ecs_iter_t = core.ecs_iter_t;
pub const ecs_poly_t = core.ecs_poly_t;
pub const ecs_strbuf_reset = core.ecs_strbuf_reset;
pub const ecs_strbuf_t = core.ecs_strbuf_t;
pub const ecs_world_t = core.ecs_world_t;

pub const ecs_from_json_desc_t = extern struct {
    /// Name of the expression, used in log messages only.
    name: ?[*:0]const u8 = null,
    /// The full expression, used in log messages only.
    expr: ?[*:0]const u8 = null,
    /// Replaces the default identifier lookup, which is `ecs_lookup`.
    lookup_action: ?*const fn (world: ?*ecs_world_t, value: ?[*:0]const u8, ctx: ?*anyopaque) callconv(.c) ecs_entity_t = null,
    lookup_ctx: ?*anyopaque = null,
    /// Fail on a component without reflection data instead of skipping its value.
    strict: bool = false,
};

/// Parse a JSON value into storage of the given type, which must be large enough to hold
/// one. Returns a pointer into `json` just past the last character read, borrowed rather
/// than owned, or null on a parse error. `desc` may be null.
pub extern fn ecs_ptr_from_json(world: *const ecs_world_t, @"type": ecs_entity_t, ptr: *anyopaque, json: [*:0]const u8, desc: ?*const ecs_from_json_desc_t) ?[*:0]const u8;

/// Parse a JSON object of component values into an entity. The format is the one
/// `ecs_entity_to_json` writes, of which only the `ids` and `values` members are read
/// back. Returns a pointer into `json` just past the last character read, or null on a
/// parse error. `desc` may be null.
pub extern fn ecs_entity_from_json(world: *ecs_world_t, entity: ecs_entity_t, json: [*:0]const u8, desc: ?*const ecs_from_json_desc_t) ?[*:0]const u8;

/// Parse a JSON object of entities into the world, in the format `ecs_world_to_json`
/// writes. Returns a pointer into `json` just past the last character read, or null on a
/// parse error. `desc` may be null.
pub extern fn ecs_world_from_json(world: *ecs_world_t, json: [*:0]const u8, desc: ?*const ecs_from_json_desc_t) ?[*:0]const u8;

/// Same as `ecs_world_from_json`, reading the JSON from a file. The returned pointer
/// points into the file contents, which are freed before this returns — so it is only
/// good for testing against null.
pub extern fn ecs_world_from_json_file(world: *ecs_world_t, filename: [*:0]const u8, desc: ?*const ecs_from_json_desc_t) ?[*:0]const u8;

/// Serialize `count` values of a type to JSON. `data` points at an array of that many
/// elements. With count 0 a single value is written, unwrapped; with count 1 or more the
/// values are written as a JSON array. Null if the type has no reflection data. Free the
/// result with `ecs_os_free`.
pub extern fn ecs_array_to_json(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque, count: i32) ?[*:0]u8;

/// Same as `ecs_array_to_json`, appending to an `ecs_strbuf_t` instead. Nonzero on
/// failure, in which case the buffer is left reset.
pub extern fn ecs_array_to_json_buf(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque, count: i32, buf_out: *ecs_strbuf_t) c_int;

/// Same as `ecs_ptr_to_json`, appending to an `ecs_strbuf_t` instead.
pub extern fn ecs_ptr_to_json_buf(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque, buf_out: *ecs_strbuf_t) c_int;

/// Serialize a type's structure to JSON, for storing or transmitting the shape of a
/// value rather than the value. A type without reflection data serializes as `"0"`.
/// Free the result with `ecs_os_free`.
pub extern fn ecs_type_info_to_json(world: *const ecs_world_t, @"type": ecs_entity_t) ?[*:0]u8;

/// Same as `ecs_type_info_to_json`, appending to an `ecs_strbuf_t` instead.
pub extern fn ecs_type_info_to_json_buf(world: *const ecs_world_t, @"type": ecs_entity_t, buf_out: *ecs_strbuf_t) c_int;

pub const ecs_entity_to_json_desc_t = extern struct {
    serialize_entity_id: bool = false,
    serialize_doc: bool = false,
    serialize_full_paths: bool = false,
    serialize_inherited: bool = false,
    serialize_values: bool = false,
    serialize_builtin: bool = false,
    serialize_type_info: bool = false,
    serialize_alerts: bool = false,
    serialize_refs: ecs_entity_t = 0,
    serialize_matches: bool = false,
    /// Decides per component whether it is serialized.
    component_filter: ?*const fn (world: ?*const ecs_world_t, component: ecs_entity_t) callconv(.c) bool = null,
};

/// Serialize an entity to JSON: its path name, the components and tags it has, and their
/// values. Null when the entity is invalid or holds a component whose value cannot be
/// serialized. `desc` may be null, which is not the same as a zeroed descriptor — see
/// `ECS_ENTITY_TO_JSON_INIT` in flecs.h for the defaults it stands in for. Free the
/// result with `ecs_os_free`.
pub extern fn ecs_entity_to_json(world: *ecs_world_t, entity: ecs_entity_t, desc: ?*const ecs_entity_to_json_desc_t) ?[*:0]u8;

/// Same as `ecs_entity_to_json`, appending to an `ecs_strbuf_t` instead.
pub extern fn ecs_entity_to_json_buf(world: *ecs_world_t, entity: ecs_entity_t, buf_out: *ecs_strbuf_t, desc: ?*const ecs_entity_to_json_desc_t) c_int;

pub const ecs_iter_to_json_desc_t = extern struct {
    serialize_entity_ids: bool = false,
    serialize_values: bool = false,
    serialize_builtin: bool = false,
    serialize_doc: bool = false,
    serialize_full_paths: bool = false,
    serialize_fields: bool = false,
    serialize_inherited: bool = false,
    serialize_table: bool = false,
    serialize_type_info: bool = false,
    serialize_field_info: bool = false,
    serialize_query_info: bool = false,
    serialize_query_plan: bool = false,
    serialize_query_profile: bool = false,
    dont_serialize_results: bool = false,
    serialize_alerts: bool = false,
    serialize_refs: ecs_entity_t = 0,
    serialize_matches: bool = false,
    serialize_parents_before_children: bool = false,
    /// Decides per component whether it is serialized.
    component_filter: ?*const fn (world: ?*const ecs_world_t, component: ecs_entity_t) callconv(.c) bool = null,
    /// Required for `serialize_query_plan` and `serialize_query_profile`.
    query: ?*ecs_poly_t = null,
};

/// Iterate an iterator to completion and serialize the results to JSON. Takes an
/// iterator from any source. `desc` may be null, which is not the same as a zeroed
/// descriptor — see `ECS_ITER_TO_JSON_INIT` in flecs.h for the defaults it stands in
/// for. Free the result with `ecs_os_free`.
pub extern fn ecs_iter_to_json(iter: *ecs_iter_t, desc: ?*const ecs_iter_to_json_desc_t) ?[*:0]u8;

/// Same as `ecs_iter_to_json`, appending to an `ecs_strbuf_t` instead.
pub extern fn ecs_iter_to_json_buf(iter: *ecs_iter_t, buf_out: *ecs_strbuf_t, desc: ?*const ecs_iter_to_json_desc_t) c_int;

pub const ecs_world_to_json_desc_t = extern struct {
    /// Include flecs's own built-in entities.
    serialize_builtin: bool = false,
    /// Include modules and what they contain.
    serialize_modules: bool = false,
};

/// Serialize the world to JSON, which is `ecs_iter_to_json` over a query matching
/// `EcsAny` with `serialize_table` set. `desc` may be null. Free the result with
/// `ecs_os_free`.
pub extern fn ecs_world_to_json(world: *ecs_world_t, desc: ?*const ecs_world_to_json_desc_t) ?[*:0]u8;

/// Same as `ecs_world_to_json`, appending to an `ecs_strbuf_t` instead.
pub extern fn ecs_world_to_json_buf(world: *ecs_world_t, buf_out: *ecs_strbuf_t, desc: ?*const ecs_world_to_json_desc_t) c_int;
