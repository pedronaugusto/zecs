//! flecs C declarations for queries and their terms.
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
pub const ecs_iter_t = core.ecs_iter_t;
pub const ecs_map_t = core.ecs_map_t;
pub const ecs_query_desc_t = core.ecs_query_desc_t;
pub const ecs_query_group_info_t = core.ecs_query_group_info_t;
pub const ecs_query_t = core.ecs_query_t;
pub const ecs_table_range_t = core.ecs_table_range_t;
pub const ecs_table_t = core.ecs_table_t;
pub const ecs_term_ref_t = core.ecs_term_ref_t;
pub const ecs_term_t = core.ecs_term_t;
pub const ecs_world_t = core.ecs_world_t;

/// Whether a term ref is set. A term ref names the entity, component or variable that
/// fills one of the three parts of a term: `src`, `first`, `second`.
pub extern fn ecs_term_ref_is_set(ref: *const ecs_term_ref_t) bool;

/// Whether a term has been initialized. The use for it is finding the last populated
/// element of a zero-initialized term array such as `ecs_query_desc_t.terms`.
pub extern fn ecs_term_is_initialized(term: *const ecs_term_t) bool;

/// Whether a term matches on `$this`, the default source for queries. True when
/// `term.src.id` is `EcsThis` and `term.src.flags` has `EcsIsVariable`. A term that
/// leaves `src` empty is given `$this` when the query is created.
pub extern fn ecs_term_match_this(term: *const ecs_term_t) bool;

/// Whether a term matches on a 0 source: matched against nothing, there only to carry a
/// component id through to the iterator. True when `term.src.id` is 0 and
/// `term.src.flags` has `EcsIsEntity`.
pub extern fn ecs_term_match_0(term: *const ecs_term_t) bool;

/// Convert a term to a query DSL expression. The expression is equivalent to the term
/// except for And and Or operators. Free the result with `ecs_os_free`.
pub extern fn ecs_term_str(world: *const ecs_world_t, term: *const ecs_term_t) ?[*:0]u8;

/// Convert a query to a query DSL expression, which parses back to the same query. Free
/// the result with `ecs_os_free`.
pub extern fn ecs_query_str(query: *const ecs_query_t) ?[*:0]u8;

pub extern fn ecs_each_id(world: *const ecs_world_t, id: ecs_id_t) ecs_iter_t;

pub extern fn ecs_each_next(it: *ecs_iter_t) bool;

/// Iterate the children of a parent. Usually the same as iterating
/// `ecs_pair(EcsChildOf, parent)`, with one exception: a parent that has the
/// `EcsOrderedChildren` trait yields a single result holding the children in order.
pub extern fn ecs_children(world: *const ecs_world_t, parent: ecs_entity_t) ecs_iter_t;

pub extern fn ecs_children_next(it: *ecs_iter_t) bool;

/// Same as `ecs_children`, over a relationship other than `EcsChildOf`.
pub extern fn ecs_children_w_rel(world: *const ecs_world_t, relationship: ecs_entity_t, parent: ecs_entity_t) ecs_iter_t;

pub extern fn ecs_query_fini(query: *ecs_query_t) void;

/// Create a query iterator. The world must be the world the query runs on, which inside
/// a system is the stage in `it.world` rather than the world the query was created with.
/// Iteration that stops before `ecs_query_next` returns false leaves resources behind;
/// release them with `ecs_iter_fini`.
pub extern fn ecs_query_iter(world: *const ecs_world_t, query: *const ecs_query_t) ecs_iter_t;

pub extern fn ecs_query_next(it: *ecs_iter_t) bool;

/// Count what the query matches. Only entities matched through `$this` are counted.
pub extern fn ecs_query_count(query: *const ecs_query_t) ecs_query_count_t;

/// Whether the query's data changed since the last iteration. True after tables or
/// entities were matched or unmatched, matched entities were deleted, or matched
/// components were written. A write through an `[out]`-only or filter term, a term not
/// matched on `$this`, and a tag term all leave it false. A table's changed state is
/// cleared when the table is iterated, so an abandoned iteration can leave tables
/// marked changed.
pub extern fn ecs_query_changed(query: *ecs_query_t) bool;

/// Replace the query held by an entity. Every handle to the previous query becomes
/// invalid; iterate with the returned one. Null if the operation failed.
pub extern fn ecs_query_update(world: *ecs_world_t, entity: ecs_entity_t, desc: *const ecs_query_desc_t) ?*ecs_query_t;

/// Find the index of a query variable by name, for `ecs_iter_set_var` and
/// `ecs_iter_get_var`. -1 when the query has no variable by that name.
pub extern fn ecs_query_find_var(query: *const ecs_query_t, name: [*:0]const u8) i32;

/// Name of a query variable. Null for an anonymous variable; index 0 is always `this`.
pub extern fn ecs_query_var_name(query: *const ecs_query_t, var_id: i32) ?[*:0]const u8;

/// Whether a query variable is an entity variable. The engine keeps entity variables
/// and table variables in one numbering, and only entity variables have a value that a
/// walk over `ecs_query_t.var_count` can read.
pub extern fn ecs_query_var_is_entity(query: *const ecs_query_t, var_id: i32) bool;

/// Match an entity against a query. On true, `it` holds the matched data and must be
/// released with `ecs_iter_fini`.
pub extern fn ecs_query_has(query: *const ecs_query_t, entity: ecs_entity_t, it: *ecs_iter_t) bool;

/// Match a table against a query. On true, `it` holds the matched data and must be
/// released with `ecs_iter_fini`.
pub extern fn ecs_query_has_table(query: *const ecs_query_t, table: *ecs_table_t, it: *ecs_iter_t) bool;

/// Match a range of a table against a query. The whole range has to match for this to
/// return true. On true, `it` holds the matched data and must be released with
/// `ecs_iter_fini`.
pub extern fn ecs_query_has_range(query: *const ecs_query_t, range: *ecs_table_range_t, it: *ecs_iter_t) bool;

/// How many match events a cached query has seen, which is what to compare against a
/// remembered value to learn whether the cache picked up new tables.
pub extern fn ecs_query_match_count(query: *const ecs_query_t) i32;

/// Render the query's execution plan, which is what to read when a query behaves in a
/// way the terms do not explain. Free the result with `ecs_os_free`.
pub extern fn ecs_query_plan(query: *const ecs_query_t) ?[*:0]u8;

/// Same as `ecs_query_plan`, annotated with what the plan actually cost. Set
/// `EcsIterProfile` in `it.flags` before iterating, or there is no profile to report.
/// Free the result with `ecs_os_free`.
pub extern fn ecs_query_plan_w_profile(query: *const ecs_query_t, it: *const ecs_iter_t) ?[*:0]u8;

/// Same as `ecs_query_plan`, and includes the plan that fills the cache when there is
/// one. Free the result with `ecs_os_free`.
pub extern fn ecs_query_plans(query: *const ecs_query_t) ?[*:0]u8;

/// Bind query variables from a key-value string: `var_a: value, var_b: value`, with
/// optional enclosing parentheses. Returns a pointer into `expr` just past the last
/// character parsed, or null on a parse error. Needs the script addon.
pub extern fn ecs_query_args_parse(query: *ecs_query_t, it: *ecs_iter_t, expr: [*:0]const u8) ?[*:0]const u8;

/// Get the query an entity holds. Null when the entity holds no query. The query stays
/// owned by the entity.
pub extern fn ecs_query_get(world: *const ecs_world_t, query: ecs_entity_t) ?*const ecs_query_t;

/// Skip the current table while iterating, so that it keeps its changed state and the
/// query leaves the table's dirty flags alone for its out fields. Only valid on a query
/// iterator whose `next` has returned true at least once.
pub extern fn ecs_iter_skip(it: *ecs_iter_t) void;

/// Restrict a query iterator to one group. The query must have a `group_by` function
/// and the iterator must be a query iterator. Call this before the first
/// `ecs_query_next`, and do not add or remove components between the two calls.
pub extern fn ecs_iter_set_group(it: *ecs_iter_t, group_id: u64) void;

/// The map of a query's active groups. The keys are group ids for `ecs_iter_set_group`;
/// the payload is opaque. Walk it with `ecs_map_iter` and `ecs_map_next`. Only valid for
/// a query that uses `group_by`. The pointer stays valid as long as the query does.
pub extern fn ecs_query_get_groups(query: *const ecs_query_t) ?*const ecs_map_t;

/// The context a query group was given by its `on_group_create` callback. Null when the
/// group does not exist.
pub extern fn ecs_query_get_group_ctx(query: *const ecs_query_t, group_id: u64) ?*anyopaque;

/// Information about a query group, including the context from `on_group_create`. Null
/// when the group does not exist.
pub extern fn ecs_query_get_group_info(query: *const ecs_query_t, group_id: u64) ?*const ecs_query_group_info_t;

pub const ecs_query_count_t = extern struct {
    results: i32 = 0,
    entities: i32 = 0,
    /// Only set for queries whose table count can be determined reliably.
    tables: i32 = 0,
};

/// Test whether a query returns one or more results.
pub extern fn ecs_query_is_true(query: *const ecs_query_t) bool;

/// The query that fills this query's cache. For a query that caches in full this is
/// equivalent to the query passed to `ecs_query_init`. Null when the query is uncached.
pub extern fn ecs_query_get_cache_query(query: *const ecs_query_t) ?*const ecs_query_t;
