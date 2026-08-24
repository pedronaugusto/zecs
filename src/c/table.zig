//! flecs C declarations for tables and their columns.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const core = @import("core.zig");
const entity = @import("entity.zig");

// Re-exported so a caller of this module sees one namespace rather than
// having to know which area a shared declaration came from.
pub const ecs_component_record_t = core.ecs_component_record_t;
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_flags32_t = core.ecs_flags32_t;
pub const ecs_flags64_t = core.ecs_flags64_t;
pub const ecs_id_t = core.ecs_id_t;
pub const ecs_read_begin = core.ecs_read_begin;
pub const ecs_read_end = core.ecs_read_end;
pub const ecs_record_find = core.ecs_record_find;
pub const ecs_record_get_by_column = core.ecs_record_get_by_column;
pub const ecs_record_t = core.ecs_record_t;
pub const ecs_ref_t = core.ecs_ref_t;
pub const ecs_table_record_t = core.ecs_table_record_t;
pub const ecs_table_t = core.ecs_table_t;
pub const ecs_type_t = core.ecs_type_t;
pub const ecs_world_t = core.ecs_world_t;
pub const ecs_write_begin = core.ecs_write_begin;
pub const ecs_write_end = core.ecs_write_end;
pub const ecs_get_table = entity.ecs_get_table;
pub const ecs_ref_get_id = entity.ecs_ref_get_id;
pub const ecs_ref_init_id = entity.ecs_ref_init_id;
pub const ecs_ref_update = entity.ecs_ref_update;
pub const ecs_table_str = entity.ecs_table_str;

/// The table's type: the vector of every component, tag and pair id it stores. Null when
/// the table is null, which is the one table operation that tolerates that.
pub extern fn ecs_table_get_type(table: ?*const ecs_table_t) ?*const ecs_type_t;

/// Index of a component in the table's type, -1 when the table does not have it.
pub extern fn ecs_table_get_type_index(world: *const ecs_world_t, table: *const ecs_table_t, component: ecs_id_t) i32;

/// Index of a component in the table's column array, -1 when the table does not have it
/// or it carries no data because it is a tag.
pub extern fn ecs_table_get_column_index(world: *const ecs_world_t, table: *const ecs_table_t, component: ecs_id_t) i32;

/// Number of columns in a table, which counts only the ids that carry data. Not the
/// same as `ecs_table_get_type(table).count`, which counts tags and pairs too.
pub extern fn ecs_table_column_count(table: *const ecs_table_t) i32;

/// Convert an index in the table type to an index in the column array. The two do not
/// line up: the column array has no entry for a tag.
pub extern fn ecs_table_type_to_column_index(table: *const ecs_table_t, index: i32) i32;

/// Convert an index in the column array to an index in the table type, the inverse of
/// `ecs_table_type_to_column_index`.
pub extern fn ecs_table_column_to_type_index(table: *const ecs_table_t, index: i32) i32;

/// A table column by column index: the array of `ecs_table_count(table) - offset`
/// component values starting at row `offset`. Pass offset 0 for the whole column. Null
/// when the index is not a component.
pub extern fn ecs_table_get_column(table: *const ecs_table_t, index: i32, offset: i32) ?*anyopaque;

/// A table column by component id, otherwise the same as `ecs_table_get_column`. Null
/// when the table does not store that component.
pub extern fn ecs_table_get_id(world: *const ecs_world_t, table: *const ecs_table_t, component: ecs_id_t, offset: i32) ?*anyopaque;

/// Element size of a table column, 0 when the index is not a component.
pub extern fn ecs_table_get_column_size(table: *const ecs_table_t, index: i32) usize;

/// Number of entities in the table.
pub extern fn ecs_table_count(table: *const ecs_table_t) i32;

/// Number of elements allocated per column, which is at least `ecs_table_count`.
pub extern fn ecs_table_size(table: *const ecs_table_t) i32;

/// The table's entity ids, `ecs_table_count(table)` of them, in row order. Owned by the
/// table and invalidated by anything that moves its rows.
pub extern fn ecs_table_entities(table: *const ecs_table_t) ?[*]const ecs_entity_t;

/// Whether a table has a component. Same as `ecs_table_get_type_index(world, table,
/// component) != -1`.
pub extern fn ecs_table_has_id(world: *const ecs_world_t, table: *const ecs_table_t, component: ecs_id_t) bool;

/// The target of a relationship for a table. `index` selects which instance, for a
/// table that holds the relationship more than once. 0 when there is none.
pub extern fn ecs_table_get_target(world: *const ecs_world_t, table: *const ecs_table_t, relationship: ecs_entity_t, index: i32) ecs_entity_t;

/// Depth of a table in the tree of a relationship, counted in targets traversed on the
/// way up. The relationship must be acyclic.
pub extern fn ecs_table_get_depth(world: *const ecs_world_t, table: *const ecs_table_t, rel: ecs_entity_t) i32;

/// The table holding everything this table holds plus one id, creating it if it does not
/// exist yet. Returns the same table when it already has the id. A null table means the
/// root table, the one an entity with no components is in.
pub extern fn ecs_table_add_id(world: *ecs_world_t, table: ?*ecs_table_t, component: ecs_id_t) ?*ecs_table_t;

/// Find or create the table holding exactly this set of ids. The array must be sorted
/// and free of duplicates; flecs does not check either.
pub extern fn ecs_table_find(world: *ecs_world_t, ids: ?[*]const ecs_id_t, id_count: i32) ?*ecs_table_t;

/// The table holding everything this table holds minus one id, creating it if it does
/// not exist yet. Returns the same table when it does not have the id. A null table
/// means the root table.
pub extern fn ecs_table_remove_id(world: *ecs_world_t, table: ?*ecs_table_t, component: ecs_id_t) ?*ecs_table_t;

/// Lock a table, so that modifying it trips an assert. Locks nest: unlock as many times
/// as you locked. Only has an effect when called on the world — on a stage operations
/// are deferred already, so this does nothing.
pub extern fn ecs_table_lock(world: *ecs_world_t, table: ?*ecs_table_t) void;

/// Undo one `ecs_table_lock`.
pub extern fn ecs_table_unlock(world: *ecs_world_t, table: ?*ecs_table_t) void;

/// Whether a table has all of the given flags. The flags live in flecs's private
/// `api_flags.h`, so this is a debugging tool rather than part of the stable surface.
pub extern fn ecs_table_has_flags(table: *ecs_table_t, flags: ecs_flags32_t) bool;

/// Whether the table holds traversable entities, meaning entities used as the target of
/// a relationship that has the `Traversable` trait.
pub extern fn ecs_table_has_traversable(table: *const ecs_table_t) bool;

/// Swap two rows of a table, the primitive a custom table sort is built from.
pub extern fn ecs_table_swap_rows(world: *ecs_world_t, table: *ecs_table_t, row_1: i32, row_2: i32) void;

/// Move an entity to a table, running the ctors, moves, dtors and `OnAdd`/`OnRemove`
/// observers the move implies. Faster than adding and removing components one at a
/// time, but the caller has to supply the difference between the two tables itself:
/// `added` and `removed` are what the observers are run for, and getting them wrong
/// silently skips observers. Both may be null when there is nothing to report. `record`
/// is optional and saves a lookup. Returns whether the entity moved.
pub extern fn ecs_commit(world: *ecs_world_t, entity: ecs_entity_t, record: ?*ecs_record_t, table: *ecs_table_t, added: ?*const ecs_type_t, removed: ?*const ecs_type_t) bool;

/// Index of the first occurrence of a component in a table's type, -1 if absent. The
/// component may be a pair or a wildcard, in which case `component_out` receives the id
/// that actually matched. Constant time.
pub extern fn ecs_search(world: *const ecs_world_t, table: *const ecs_table_t, component: ecs_id_t, component_out: ?*ecs_id_t) i32;

/// Same as `ecs_search`, starting from an offset in the table type, so that a loop that
/// feeds back `index + 1` walks every match. Constant time for `(id)` and `(rel, *)`
/// used that way; linear for `(*, tgt)`, because ids are sorted relationship-first.
pub extern fn ecs_search_offset(world: *const ecs_world_t, table: *const ecs_table_t, offset: i32, component: ecs_id_t, component_out: ?*ecs_id_t) i32;

/// Same as `ecs_search_offset`, and follows a relationship to find the component — on a
/// prefab reached through `IsA`, for instance. `flags` is `EcsSelf`, `EcsUp` or both,
/// and defaults to both when 0. The search is depth-first. `tgt_out`, `component_out`
/// and `tr_out` are optional out parameters; `tr_out` is a flecs-internal type. Prefer
/// the simpler `ecs_search` or `ecs_search_offset` where they suffice — they are faster.
pub extern fn ecs_search_relation(world: *const ecs_world_t, table: *const ecs_table_t, offset: i32, component: ecs_id_t, rel: ecs_entity_t, flags: ecs_flags64_t, tgt_out: ?*ecs_entity_t, component_out: ?*ecs_id_t, tr_out: ?*?*ecs_table_record_t) i32;

/// Same as `ecs_search_relation`, starting from an entity rather than a table. `cr` is
/// an optional component record for `id` that saves a lookup. -1 if not found.
pub extern fn ecs_search_relation_for_entity(world: *const ecs_world_t, entity: ecs_entity_t, id: ecs_id_t, rel: ecs_entity_t, self: bool, cr: ?*ecs_component_record_t, tgt_out: ?*ecs_entity_t, id_out: ?*ecs_id_t, tr_out: ?*?*ecs_table_record_t) i32;

/// Remove every entity from a table without releasing its memory, which is worth doing
/// when the table is about to be refilled by something like `ecs_bulk_init`.
pub extern fn ecs_table_clear_entities(world: *ecs_world_t, table: *ecs_table_t) void;
