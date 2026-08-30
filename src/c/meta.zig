//! flecs C declarations for runtime reflection.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const core = @import("core.zig");
const abi = @import("abi.zig");

// Re-exported so a caller of this module sees one namespace rather than
// having to know which area a shared declaration came from.
pub const EcsOpaque = core.EcsOpaque;
pub const ecs_entity_desc_t = core.ecs_entity_desc_t;
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_hashmap_t = core.ecs_hashmap_t;
pub const ecs_id_t = core.ecs_id_t;
pub const ecs_map_t = core.ecs_map_t;
pub const ecs_member_t = core.ecs_member_t;
pub const ecs_member_value_range_t = core.ecs_member_value_range_t;
pub const ecs_meta_serialize_t = core.ecs_meta_serialize_t;
pub const ecs_primitive_kind_t = core.ecs_primitive_kind_t;
pub const ecs_size_t = core.ecs_size_t;
pub const ecs_type_info_t = core.ecs_type_info_t;
pub const ecs_value_t = core.ecs_value_t;
pub const ecs_vec_t = core.ecs_vec_t;
pub const ecs_world_t = core.ecs_world_t;

pub extern const EcsQuantity: ecs_entity_t;

/// One of the `Ecs*Type` constants. Declared as the integer the C enum compiles to on
/// this target — `abi.c_enum` — so that a value flecs invents at runtime is
/// representable, on either Windows ABI.
pub const ecs_type_kind_t = abi.c_enum;

/// Added to every entity that has reflection data.
pub const EcsType = extern struct {
    kind: ecs_type_kind_t = 0,
    /// Whether the type already existed rather than being created from reflection data.
    existing: bool = false,
    /// Whether the reflection data describes only part of the type.
    partial: bool = false,
};

/// Added to primitive type entities.
pub const EcsPrimitive = extern struct {
    kind: ecs_primitive_kind_t = 0,
};

/// Added to the child entity that describes one struct member.
pub const EcsMember = extern struct {
    type: ecs_entity_t = 0,
    /// Element count for an inline array member, 0 otherwise.
    count: i32 = 0,
    unit: ecs_entity_t = 0,
    offset: i32 = 0,
    /// Use `offset` as given instead of computing it.
    use_offset: bool = false,
};

/// Added to a member entity to say which values are sensible, which are worth a warning,
/// and which are wrong. Nothing enforces them; they are there for a UI to render.
pub const EcsMemberRanges = extern struct {
    value: ecs_member_value_range_t = .{},
    warning: ecs_member_value_range_t = .{},
    @"error": ecs_member_value_range_t = .{},
};

/// Added to struct type entities.
pub const EcsStruct = extern struct {
    /// `ecs_vec_t` of `ecs_member_t`, built from the child entities that have `EcsMember`.
    members: ecs_vec_t = .{},
};

pub const ecs_enum_constant_t = extern struct {
    /// Required in `ecs_enum_desc_t`.
    name: ?[*:0]const u8 = null,
    value: i64 = 0,
    /// Used instead of `value` when the underlying type is unsigned.
    value_unsigned: u64 = 0,
    /// Set by flecs. Do not set in `ecs_enum_desc_t`.
    constant: ecs_entity_t = 0,
};

/// Added to bitmask type entities. It carries no data of its own; the constants live in
/// `EcsConstants`.
pub const EcsBitmask = extern struct {
    dummy_: i32 = 0,
};

/// Added to enum and bitmask type entities, holding the constants for lookup in both
/// directions.
pub const EcsConstants = extern struct {
    /// `ecs_map_t` from value to `ecs_enum_constant_t`, built from the child entities
    /// that have `EcsConstant`.
    constants: ?*ecs_map_t = null,
    /// `ecs_vec_t` of the same constants in registration order.
    ordered_constants: ecs_vec_t = .{},
};

/// Added to array type entities: a fixed-size array of `count` elements.
pub const EcsArray = extern struct {
    type: ecs_entity_t = 0,
    count: i32 = 0,
};

/// Added to vector type entities: a resizable array, stored as an `ecs_vec_t`.
pub const EcsVector = extern struct {
    type: ecs_entity_t = 0,
};

/// How a derived unit relates to its base, as `factor * 10^power`. A translation of 1000
/// can be written either way round.
pub const ecs_unit_translation_t = extern struct {
    factor: i32 = 0,
    power: i32 = 0,
};

/// Added to unit entities. Owned by flecs.
pub const EcsUnit = extern struct {
    symbol: ?[*:0]u8 = null,
    /// Order-of-magnitude prefix relative to the derived unit.
    prefix: ecs_entity_t = 0,
    /// Base unit, as "meters" is for "meters per second".
    base: ecs_entity_t = 0,
    /// Over unit, as "seconds" is for "meters per second".
    over: ecs_entity_t = 0,
    translation: ecs_unit_translation_t = .{},
};

/// Added to unit prefix entities, such as "kilo" or "kibi". Owned by flecs.
pub const EcsUnitPrefix = extern struct {
    symbol: ?[*:0]u8 = null,
    translation: ecs_unit_translation_t = .{},
};

/// One of the `EcsOp*` constants. Declared as the integer the C enum compiles to, for the
/// same reason as `ecs_type_kind_t`.
pub const ecs_meta_op_kind_t = abi.c_enum;

/// One instruction of a type's flattened serializer program, telling a serializer what
/// is at which offset.
pub const ecs_meta_op_t = extern struct {
    kind: ecs_meta_op_kind_t = 0,
    /// The underlying kind, for an enum.
    underlying_kind: ecs_meta_op_kind_t = 0,
    /// Offset of the field within the value being walked.
    offset: ecs_size_t = 0,
    /// Only set for a struct member.
    name: ?[*:0]const u8 = null,
    /// Element size for a push of an array or vector; element count for the matching pop.
    elem_size: ecs_size_t = 0,
    /// How many instructions until the next field or the end of the program, which is
    /// how a whole nested scope is skipped.
    op_count: i16 = 0,
    member_index: i16 = 0,
    type: ecs_entity_t = 0,
    type_info: ?*const ecs_type_info_t = null,
    /// Which member is live depends on `kind`.
    is: extern union {
        /// Struct: `ecs_hashmap_t` from member name to member index.
        members: ?*ecs_hashmap_t,
        /// Enum and bitmask: `ecs_map_t` from value to constant entity.
        constants: ?*ecs_map_t,
        /// Opaque type: its serialize callback.
        @"opaque": ecs_meta_serialize_t,
    },
};

/// Added to every type with reflection data, holding its serializer program.
pub const EcsTypeSerializer = extern struct {
    /// Same as `EcsType.kind`, kept here so a serializer needs one lookup rather than two.
    kind: ecs_type_kind_t = 0,
    /// `ecs_vec_t` of `ecs_meta_op_t`.
    ops: ecs_vec_t = .{},
};

/// One level of a meta cursor's scope stack.
pub const ecs_meta_scope_t = extern struct {
    type: ecs_entity_t = 0,
    /// The scope's serializer program, `ops_count` instructions long.
    ops: ?[*]ecs_meta_op_t = null,
    ops_count: i16 = 0,
    ops_cur: i16 = 0,
    /// Depth to return to, for a scope entered through `ecs_meta_dotmember`.
    prev_depth: i16 = 0,
    /// The value being walked. flecs.h calls this "pointer to ops[0]", which is wrong:
    /// field pointers are computed as this plus the current op's offset.
    ptr: ?*anyopaque = null,
    /// Set when the scope's type is opaque.
    @"opaque": ?*const EcsOpaque = null,
    /// `ecs_hashmap_t` from member name to member index.
    members: ?*ecs_hashmap_t = null,
    is_collection: bool = false,
    /// Whether the scope turned out to hold no elements, for a vector.
    is_empty_scope: bool = false,
    /// Whether the scope was entered through `ecs_meta_elem`, for a vector.
    is_moved_scope: bool = false,
    elem: i32 = 0,
    elem_count: i32 = 0,
};

/// A position in a value being read or written through reflection. Holds its scope stack
/// inline, so it is large; pass it by pointer.
pub const ecs_meta_cursor_t = extern struct {
    world: ?*const ecs_world_t = null,
    /// Scope stack, `ECS_META_MAX_SCOPE_DEPTH` levels deep.
    scope: [32]ecs_meta_scope_t = @splat(.{}),
    depth: i16 = 0,
    /// False when the cursor could not be created or has walked off the value. Check it
    /// after `ecs_meta_cursor`.
    valid: bool = false,
    is_primitive_scope: bool = false,
    /// Replaces the default identifier lookup, which is `ecs_lookup`.
    lookup_action: ?*const fn (world: ?*ecs_world_t, value: ?[*:0]const u8, ctx: ?*anyopaque) callconv(.c) ecs_entity_t = null,
    lookup_ctx: ?*anyopaque = null,
};

/// Render a type's serializer program as text, one instruction per line. Null when the
/// type has no reflection data. Free the result with `ecs_os_free`.
pub extern fn ecs_meta_serializer_to_str(world: *ecs_world_t, @"type": ecs_entity_t) ?[*:0]u8;

/// Create a cursor for walking, reading and writing a value whose type is not known at
/// compile time. Assignment converts: a string can set an integer field, an integer can
/// set a float, and so on, so the stored layout can change without the caller changing.
/// Check `valid` on the result — a type without reflection data yields an invalid cursor
/// rather than an error.
pub extern fn ecs_meta_cursor(world: *const ecs_world_t, @"type": ecs_entity_t, ptr: *anyopaque) ecs_meta_cursor_t;

/// Pointer to the current field, for reading or writing it directly.
pub extern fn ecs_meta_get_ptr(cursor: *ecs_meta_cursor_t) ?*anyopaque;

/// Move to the next field of the current scope.
pub extern fn ecs_meta_next(cursor: *ecs_meta_cursor_t) c_int;

/// Move to an element by index, inside a collection scope.
pub extern fn ecs_meta_elem(cursor: *ecs_meta_cursor_t, elem: i32) c_int;

/// Move to a member by name, inside a struct scope.
pub extern fn ecs_meta_member(cursor: *ecs_meta_cursor_t, name: [*:0]const u8) c_int;

/// Same as `ecs_meta_member`, returning nonzero quietly instead of logging an error for
/// a name the struct does not have.
pub extern fn ecs_meta_try_member(cursor: *ecs_meta_cursor_t, name: [*:0]const u8) c_int;

/// Same as `ecs_meta_member`, and accepts a dotted path that descends into nested
/// structs. The scopes it entered are unwound by the next `ecs_meta_pop`.
pub extern fn ecs_meta_dotmember(cursor: *ecs_meta_cursor_t, name: [*:0]const u8) c_int;

/// Same as `ecs_meta_dotmember`, returning nonzero quietly instead of logging an error.
pub extern fn ecs_meta_try_dotmember(cursor: *ecs_meta_cursor_t, name: [*:0]const u8) c_int;

/// Descend into the current field, which must be a struct or a collection. Required
/// before reading or writing anything inside one.
pub extern fn ecs_meta_push(cursor: *ecs_meta_cursor_t) c_int;

/// Leave the current scope, matching an earlier `ecs_meta_push`.
pub extern fn ecs_meta_pop(cursor: *ecs_meta_cursor_t) c_int;

/// Is the current scope a collection?
pub extern fn ecs_meta_is_collection(cursor: *const ecs_meta_cursor_t) bool;

/// Get type of current field.
pub extern fn ecs_meta_get_type(cursor: *const ecs_meta_cursor_t) ecs_entity_t;

/// Get unit of current field.
pub extern fn ecs_meta_get_unit(cursor: *const ecs_meta_cursor_t) ecs_entity_t;

/// Name of the current field, null when the scope is not a struct. Owned by the
/// reflection data.
pub extern fn ecs_meta_get_member(cursor: *const ecs_meta_cursor_t) ?[*:0]const u8;

/// Get member entity of current field.
pub extern fn ecs_meta_get_member_id(cursor: *const ecs_meta_cursor_t) ecs_entity_t;

/// Set field with boolean value.
pub extern fn ecs_meta_set_bool(cursor: *ecs_meta_cursor_t, value: bool) c_int;

/// Set field with char value.
pub extern fn ecs_meta_set_char(cursor: *ecs_meta_cursor_t, value: u8) c_int;

/// Set field with int value.
pub extern fn ecs_meta_set_int(cursor: *ecs_meta_cursor_t, value: i64) c_int;

/// Set field with uint value.
pub extern fn ecs_meta_set_uint(cursor: *ecs_meta_cursor_t, value: u64) c_int;

/// Set field with float value.
pub extern fn ecs_meta_set_float(cursor: *ecs_meta_cursor_t, value: f64) c_int;

/// Set the current field from a string, converting to the field's type.
pub extern fn ecs_meta_set_string(cursor: *ecs_meta_cursor_t, value: ?[*:0]const u8) c_int;

/// Same as `ecs_meta_set_string`, for a value that still carries its enclosing quotes.
pub extern fn ecs_meta_set_string_literal(cursor: *ecs_meta_cursor_t, value: ?[*:0]const u8) c_int;

/// Set field with entity value.
pub extern fn ecs_meta_set_entity(cursor: *ecs_meta_cursor_t, value: ecs_entity_t) c_int;

/// Set field with (component) ID value.
pub extern fn ecs_meta_set_id(cursor: *ecs_meta_cursor_t, value: ecs_id_t) c_int;

/// Set field with null value.
pub extern fn ecs_meta_set_null(cursor: *ecs_meta_cursor_t) c_int;

/// Set the current field from a typed value, converting as the other setters do.
pub extern fn ecs_meta_set_value(cursor: *ecs_meta_cursor_t, value: *const ecs_value_t) c_int;

/// Get field value as boolean.
pub extern fn ecs_meta_get_bool(cursor: *const ecs_meta_cursor_t) bool;

/// Get field value as char.
pub extern fn ecs_meta_get_char(cursor: *const ecs_meta_cursor_t) u8;

/// Get field value as signed integer.
pub extern fn ecs_meta_get_int(cursor: *const ecs_meta_cursor_t) i64;

/// Get field value as unsigned integer.
pub extern fn ecs_meta_get_uint(cursor: *const ecs_meta_cursor_t) u64;

/// Get field value as float.
pub extern fn ecs_meta_get_float(cursor: *const ecs_meta_cursor_t) f64;

/// Read the current field as a string. Unlike the other getters this does not convert:
/// the field has to be a string, or an opaque type that maps to one. The string belongs
/// to the value being walked.
pub extern fn ecs_meta_get_string(cursor: *const ecs_meta_cursor_t) ?[*:0]const u8;

/// Read the current field as an entity. Does not convert.
pub extern fn ecs_meta_get_entity(cursor: *const ecs_meta_cursor_t) ecs_entity_t;

/// Read the current field as a component id, converting from an entity if need be.
pub extern fn ecs_meta_get_id(cursor: *const ecs_meta_cursor_t) ecs_id_t;

/// Read a value of a primitive kind as a float. `ptr` must point at a value of that
/// kind.
pub extern fn ecs_meta_ptr_to_float(type_kind: ecs_primitive_kind_t, ptr: *const anyopaque) f64;

/// Element count for a push instruction. `op` points into a serializer program rather
/// than at a lone instruction: for `EcsOpPushArray` the count is read from the matching
/// pop, `op[op.op_count - 1]`, and `ptr` is not used and may be null. For
/// `EcsOpPushVector` the count comes from the `ecs_vec_t` at `ptr`. Any other kind
/// fails.
pub extern fn ecs_meta_op_get_elem_count(op: [*]const ecs_meta_op_t, ptr: ?*const anyopaque) ecs_size_t;

pub const ecs_enum_desc_t = extern struct {
    /// Existing entity to attach the type to. 0 creates one.
    entity: ecs_entity_t = 0,
    /// Terminated by the first entry with a null name.
    constants: [32]ecs_enum_constant_t = @splat(.{}),
    underlying_type: ecs_entity_t = 0,
};

/// Register an enum type. 0 on failure.
pub extern fn ecs_enum_init(world: *ecs_world_t, desc: *const ecs_enum_desc_t) ecs_entity_t;

pub const ecs_vector_desc_t = extern struct {
    /// Existing entity to attach the type to. 0 creates one.
    entity: ecs_entity_t = 0,
    type: ecs_entity_t = 0,
};

/// Register a vector type, whose values are `ecs_vec_t`. 0 on failure.
pub extern fn ecs_vector_init(world: *ecs_world_t, desc: *const ecs_vector_desc_t) ecs_entity_t;

pub const ecs_struct_desc_t = extern struct {
    /// Existing entity to attach the type to. 0 creates one.
    entity: ecs_entity_t = 0,
    /// Terminated by the first entry with a null name.
    members: [32]ecs_member_t = @splat(.{}),
    /// Give each member its own entity, which member queries, metrics and alerts all
    /// need. A flecs built with `FLECS_CREATE_MEMBER_ENTITIES` does this regardless.
    create_member_entities: bool = false,
};

/// Register a struct type. 0 on failure.
pub extern fn ecs_struct_init(world: *ecs_world_t, desc: *const ecs_struct_desc_t) ecs_entity_t;

/// Find a struct member by name. Null when the type is not a struct or has no such
/// member. The pointer aims into the type's members vector, so adding a member
/// invalidates it.
pub extern fn ecs_struct_get_member(world: *ecs_world_t, @"type": ecs_entity_t, name: [*:0]const u8) ?*ecs_member_t;

/// Same as `ecs_struct_get_member`, by index rather than name.
pub extern fn ecs_struct_get_nth_member(world: *ecs_world_t, @"type": ecs_entity_t, i: i32) ?*ecs_member_t;

pub const ecs_unit_desc_t = extern struct {
    /// Existing entity to attach the unit to. 0 creates one.
    entity: ecs_entity_t = 0,
    symbol: ?[*:0]const u8 = null,
    /// The quantity this unit measures, such as length.
    quantity: ecs_entity_t = 0,
    base: ecs_entity_t = 0,
    over: ecs_entity_t = 0,
    translation: ecs_unit_translation_t = .{},
    prefix: ecs_entity_t = 0,
};

/// Register a unit. 0 on failure.
pub extern fn ecs_unit_init(world: *ecs_world_t, desc: *const ecs_unit_desc_t) ecs_entity_t;

pub const ecs_unit_prefix_desc_t = extern struct {
    /// Existing entity to attach the prefix to. 0 creates one.
    entity: ecs_entity_t = 0,
    symbol: ?[*:0]const u8 = null,
    translation: ecs_unit_translation_t = .{},
};

/// Register a unit prefix, such as "kilo". 0 on failure.
pub extern fn ecs_unit_prefix_init(world: *ecs_world_t, desc: *const ecs_unit_prefix_desc_t) ecs_entity_t;

/// Register a quantity: the thing a family of units measures, such as length, which the
/// units then point at through `ecs_unit_desc_t.quantity`. 0 on failure.
pub extern fn ecs_quantity_init(world: *ecs_world_t, desc: *const ecs_entity_desc_t) ecs_entity_t;

/// Import the meta module, the equivalent of `ECS_IMPORT(world, FlecsMeta)` in C.
pub extern fn FlecsMetaImport(world: *ecs_world_t) void;

/// Register reflection data for a component from a type descriptor string, which is what
/// flecs's `ECS_META_COMPONENT` macro expands to a call of. The descriptor is the body
/// of the C declaration, and `kind` says how to read it.
pub extern fn ecs_meta_from_desc(world: *ecs_world_t, component: ecs_entity_t, kind: ecs_type_kind_t, desc: [*:0]const u8) c_int;
