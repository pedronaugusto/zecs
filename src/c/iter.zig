//! flecs C declarations for iterators over query results.
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
pub const ecs_iter_action_t = core.ecs_iter_action_t;
pub const ecs_iter_t = core.ecs_iter_t;
pub const ecs_table_range_t = core.ecs_table_range_t;
pub const ecs_table_t = core.ecs_table_t;
pub const ecs_var_t = core.ecs_var_t;

/// Progress any iterator, whatever created it. Slower than the type-specific `next`
/// functions by one indirect call, and the reason to reach for it is code that has to
/// accept iterators it did not create.
pub extern fn ecs_iter_next(it: *ecs_iter_t) bool;

/// Release an iterator's resources. Only needed for an iterator that was abandoned
/// before its `next` returned false; one iterated to completion frees itself.
pub extern fn ecs_iter_fini(it: *ecs_iter_t) void;

/// Count the entities an iterator matches, by iterating it to completion. 0 for a query
/// that yields results without matching entities, such as one with no `$this` terms.
pub extern fn ecs_iter_count(it: *ecs_iter_t) i32;

/// Whether an iterator yields at least one result. Consumes the iterator: afterwards,
/// treat it as iterated to completion and do not call `next` on it again.
pub extern fn ecs_iter_is_true(it: *ecs_iter_t) bool;

/// The first entity an iterator matches, 0 if it matches none. Consumes the iterator,
/// as `ecs_iter_is_true` does.
pub extern fn ecs_iter_first(it: *ecs_iter_t) ecs_entity_t;

/// Constrain an iterator variable to one entity, so that only results where the
/// variable equals it are returned. Variables default to `EcsWildcard`, which matches
/// anything. Set it after creating the iterator and before the first `next`.
pub extern fn ecs_iter_set_var(it: *ecs_iter_t, var_id: i32, entity: ecs_entity_t) void;

/// Same as `ecs_iter_set_var`, constraining the variable to every entity in a table.
pub extern fn ecs_iter_set_var_as_table(it: *ecs_iter_t, var_id: i32, table: *const ecs_table_t) void;

/// Same as `ecs_iter_set_var`, constraining the variable to a range of a table. The
/// range must lie inside the table.
pub extern fn ecs_iter_set_var_as_range(it: *ecs_iter_t, var_id: i32, range: *const ecs_table_range_t) void;

/// Read an iterator variable as an entity, which works when it holds an entity or a
/// table range of one element. `var_id` must be below `ecs_iter_get_var_count`.
pub extern fn ecs_iter_get_var(it: *ecs_iter_t, var_id: i32) ecs_entity_t;

/// Name of an iterator variable. Index 0 is always `this`; null for an iterator that is
/// not iterating a query.
pub extern fn ecs_iter_get_var_name(it: *const ecs_iter_t, var_id: i32) ?[*:0]const u8;

pub extern fn ecs_iter_get_var_count(it: *const ecs_iter_t) i32;

/// The iterator's variable array, `ecs_iter_get_var_count` elements long. Null for an
/// iterator that is not iterating a query. Owned by the iterator.
pub extern fn ecs_iter_get_vars(it: *const ecs_iter_t) ?[*]ecs_var_t;

/// Get the value of an iterator variable as a table. A variable can be interpreted as a
/// table if it is set as a table range with both offset and count set to 0, or if
/// offset is 0 and count matches the number of elements in the table.
pub extern fn ecs_iter_get_var_as_table(it: *ecs_iter_t, var_id: i32) ?*ecs_table_t;

/// Get the value of an iterator variable as a table range. A value can be interpreted
/// as a table range if it is set as a table range, or if it is set to an entity with a
/// non-empty type (the entity must have at least one component, tag, or relationship in
/// its type).
pub extern fn ecs_iter_get_var_as_range(it: *ecs_iter_t, var_id: i32) ecs_table_range_t;

/// Whether a variable was fixed by one of the `ecs_iter_set_var` operations. A
/// constrained variable will not change value while results are iterated.
pub extern fn ecs_iter_var_is_constrained(it: *ecs_iter_t, var_id: i32) bool;

/// The group id of the current result. Only valid while iterating a query that uses
/// `group_by`; for a query that uses cascade this is the hierarchy depth instead.
pub extern fn ecs_iter_get_group(it: *const ecs_iter_t) u64;

/// Whether the current result changed since the query last iterated it. Requires a
/// query that supports change detection, which means a cached one. Detection is
/// per table: a change to one entity is not distinguishable from a change to its
/// neighbours.
pub extern fn ecs_iter_changed(it: *ecs_iter_t) bool;

/// Render the current result as a string, for debugging and tests. Covers the current
/// result only — call it once per `next` to see everything. Null when the iterator holds
/// no valid result. Free the result with `ecs_os_free`.
pub extern fn ecs_iter_str(it: *const ecs_iter_t) ?[*:0]u8;

/// Wrap an iterator so it skips the first `offset` entities and yields at most `limit`.
/// Iterate the result with `ecs_page_next`; it passes through everything the parent
/// iterator provides.
pub extern fn ecs_page_iter(it: *const ecs_iter_t, offset: i32, limit: i32) ecs_iter_t;

pub extern fn ecs_page_next(it: *ecs_iter_t) bool;

/// Wrap an iterator so it yields this worker's share of the matched entities: the total
/// divided by `count`, at index `index`. The split is stable, so two queries that match
/// the same table hand the same entities to the same worker. Iterate the result with
/// `ecs_worker_next`.
pub extern fn ecs_worker_iter(it: *const ecs_iter_t, index: i32, count: i32) ecs_iter_t;

pub extern fn ecs_worker_next(it: *ecs_iter_t) bool;

/// The data for a field. When the field is matched on the iterated entities this points
/// at an array of `it.count` elements; when it is matched elsewhere — a prefab, a
/// parent, a fixed entity — it points at a single value, and `ecs_field_is_self` is what
/// tells the two apart. `size` must be the field's own size, or anything when the field
/// carries no data — flecs.h says 0 is also accepted, but flecs.c asserts on it here.
/// `ecs_field_size` is where the size comes from. Use `ecs_field_at_w_size` for a sparse
/// component.
pub extern fn ecs_field_w_size(it: *const ecs_iter_t, size: usize, index: i8) ?*anyopaque;

/// The data for one row of a field. This is the form to use for a sparse component,
/// whose elements are not contiguous and so cannot be reached by indexing
/// `ecs_field_w_size`. Here `size` may be 0, which skips the size check.
pub extern fn ecs_field_at_w_size(it: *const ecs_iter_t, size: usize, index: i8, row: i32) ?*anyopaque;

pub extern fn ecs_field_is_set(it: *const ecs_iter_t, index: i8) bool;

/// Whether the field is matched on the iterated entities rather than owned by another
/// entity such as a parent or a prefab. False means `ecs_field_w_size` returned one
/// value rather than an array of `it.count`.
pub extern fn ecs_field_is_self(it: *const ecs_iter_t, index: i8) bool;

/// Whether the field is read-only, which means its term is annotated `[in]`.
pub extern fn ecs_field_is_readonly(it: *const ecs_iter_t, index: i8) bool;

pub extern fn ecs_field_id(it: *const ecs_iter_t, index: i8) ecs_id_t;

/// The entity the field was matched on.
pub extern fn ecs_field_src(it: *const ecs_iter_t, index: i8) ecs_entity_t;

/// Size of the field's type, 0 when the field carries no data.
pub extern fn ecs_field_size(it: *const ecs_iter_t, index: i8) usize;

/// Whether the field is write-only, which means its term is annotated `[out]`. A
/// serializer is free to leave such a field's value out.
pub extern fn ecs_field_is_writeonly(it: *const ecs_iter_t, index: i8) bool;

/// The index of the table column a field was matched to. -1 for a field matched on
/// anything other than `$this`.
pub extern fn ecs_field_column(it: *const ecs_iter_t, index: i8) i32;
