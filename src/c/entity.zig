//! flecs C declarations for entities, components and id arithmetic.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const core = @import("core.zig");
const query = @import("query.zig");
const system = @import("system.zig");
const world = @import("world.zig");

// Re-exported so a caller of this module sees one namespace rather than
// having to know which area a shared declaration came from.
pub const FLECS_ID_DESC_MAX = core.FLECS_ID_DESC_MAX;
pub const ecs_bulk_desc_t = core.ecs_bulk_desc_t;
pub const ecs_component_init = core.ecs_component_init;
pub const ecs_entity_init = core.ecs_entity_init;
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_flags32_t = core.ecs_flags32_t;
pub const ecs_ftime_t = core.ecs_ftime_t;
pub const ecs_has_id = core.ecs_has_id;
pub const ecs_id_str = core.ecs_id_str;
pub const ecs_id_t = core.ecs_id_t;
pub const ecs_query_init = core.ecs_query_init;
pub const ecs_ref_t = core.ecs_ref_t;
pub const ecs_set_id = core.ecs_set_id;
pub const ecs_strbuf_t = core.ecs_strbuf_t;
pub const ecs_table_t = core.ecs_table_t;
pub const ecs_type_hooks_t = core.ecs_type_hooks_t;
pub const ecs_type_info_t = core.ecs_type_info_t;
pub const ecs_type_t = core.ecs_type_t;
pub const ecs_world_t = core.ecs_world_t;
pub const ecs_children = query.ecs_children;
pub const ecs_children_next = query.ecs_children_next;
pub const ecs_each_id = query.ecs_each_id;
pub const ecs_each_next = query.ecs_each_next;
pub const ecs_observer_init = system.ecs_observer_init;
pub const ecs_run = system.ecs_run;
pub const ecs_system_init = system.ecs_system_init;
pub const ecs_defer_begin = world.ecs_defer_begin;
pub const ecs_defer_end = world.ecs_defer_end;
pub const ecs_defer_resume = world.ecs_defer_resume;
pub const ecs_defer_suspend = world.ecs_defer_suspend;
pub const ecs_entities_t = world.ecs_entities_t;
pub const ecs_exclusive_access_begin = world.ecs_exclusive_access_begin;
pub const ecs_exclusive_access_end = world.ecs_exclusive_access_end;
pub const ecs_fini = world.ecs_fini;
pub const ecs_frame_begin = world.ecs_frame_begin;
pub const ecs_frame_end = world.ecs_frame_end;
pub const ecs_get_stage = world.ecs_get_stage;
pub const ecs_get_stage_count = world.ecs_get_stage_count;
pub const ecs_init = world.ecs_init;
pub const ecs_is_deferred = world.ecs_is_deferred;
pub const ecs_mini = world.ecs_mini;
pub const ecs_progress = world.ecs_progress;
pub const ecs_quit = world.ecs_quit;
pub const ecs_readonly_begin = world.ecs_readonly_begin;
pub const ecs_readonly_end = world.ecs_readonly_end;
pub const ecs_set_stage_count = world.ecs_set_stage_count;
pub const ecs_set_target_fps = world.ecs_set_target_fps;
pub const ecs_set_task_threads = world.ecs_set_task_threads;
pub const ecs_set_threads = world.ecs_set_threads;
pub const ecs_should_quit = world.ecs_should_quit;

pub extern fn ecs_new(world: *ecs_world_t) ecs_entity_t;

pub extern fn ecs_new_w_id(world: *ecs_world_t, id: ecs_id_t) ecs_entity_t;

pub extern fn ecs_new_low_id(world: *ecs_world_t) ecs_entity_t;

pub extern fn ecs_clone(world: *ecs_world_t, dst: ecs_entity_t, src: ecs_entity_t, copy_value: bool) ecs_entity_t;

pub extern fn ecs_delete(world: *ecs_world_t, entity: ecs_entity_t) void;

pub extern fn ecs_delete_with(world: *ecs_world_t, id: ecs_id_t) void;

pub extern fn ecs_is_alive(world: *const ecs_world_t, entity: ecs_entity_t) bool;

pub extern fn ecs_is_valid(world: *const ecs_world_t, entity: ecs_entity_t) bool;

pub extern fn ecs_exists(world: *const ecs_world_t, entity: ecs_entity_t) bool;

pub extern fn ecs_get_alive(world: *const ecs_world_t, entity: ecs_entity_t) ecs_entity_t;

/// Create an entity directly in a table, so it arrives with every component that table
/// holds and no intermediate ones.
pub extern fn ecs_new_w_table(world: *ecs_world_t, table: *ecs_table_t) ecs_entity_t;

/// Insert `desc.count` entities into one table in a single pass. Returns them as an array
/// of `desc.count`. If `desc.entities` was set that array is what comes back; if it was
/// not, the result points into flecs's own storage and the next entity created or deleted
/// invalidates it — including one created by an observer this call runs, which is the
/// argument for copying it out before doing anything else.
pub extern fn ecs_bulk_init(world: *ecs_world_t, desc: *const ecs_bulk_desc_t) ?[*]const ecs_entity_t;

/// Same as `ecs_new_w_id`, but creates `count` entities. Returns them as an array of
/// `count`, borrowed from flecs and invalidated by the next entity created or deleted.
pub extern fn ecs_bulk_new_w_id(world: *ecs_world_t, component: ecs_id_t, count: i32) ?[*]const ecs_entity_t;

/// Reorder a parent's children to match `children[0..child_count]`, which must be exactly
/// the set it already has. Needs the `EcsOrderedChildren` trait on the parent; without it
/// the call fails.
pub extern fn ecs_set_child_order(world: *ecs_world_t, parent: ecs_entity_t, children: ?[*]const ecs_entity_t, child_count: i32) void;

/// The children of a parent, in order. Needs the `EcsOrderedChildren` trait on the
/// parent; without it the call fails and the result is empty. All of them are alive, so
/// `count` and `alive_count` agree.
pub extern fn ecs_get_ordered_children(world: *const ecs_world_t, parent: ecs_entity_t) ecs_entities_t;

pub extern fn ecs_add_id(world: *ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) void;

pub extern fn ecs_remove_id(world: *ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) void;

pub extern fn ecs_get_id(world: *const ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) ?*const anyopaque;

pub extern fn ecs_get_mut_id(world: *const ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) ?*anyopaque;

pub extern fn ecs_ensure_id(world: *ecs_world_t, entity: ecs_entity_t, id: ecs_id_t, size: usize) ?*anyopaque;

pub extern fn ecs_modified_id(world: *ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) void;

pub extern fn ecs_owns_id(world: *const ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) bool;

pub extern fn ecs_enable(world: *ecs_world_t, entity: ecs_entity_t, enabled: bool) void;

/// Mark a component on a prefab so that instances get their own copy of it rather than
/// sharing the prefab's. Set on the prefab, not the instance, and equivalent to adding
/// the id with the `ECS_AUTO_OVERRIDE` bit. Only meaningful for a component with the
/// `(OnInstantiate, Inherit)` trait, since that is the only one instances share.
pub extern fn ecs_auto_override_id(world: *ecs_world_t, entity: ecs_entity_t, component: ecs_id_t) void;

/// Clear all components. This operation will remove all components from an entity.
pub extern fn ecs_clear(world: *ecs_world_t, entity: ecs_entity_t) void;

/// Remove all instances of the specified component. This will remove the specified ID
/// from all entities (tables). The ID may be a wildcard and/or a pair.
pub extern fn ecs_remove_all(world: *ecs_world_t, component: ecs_id_t) void;

/// Create new entities with a specified component. This operation configures a
/// component that is automatically added to entities created with ecs_entity_init().
/// This does not apply to entities created with ecs_new().
pub extern fn ecs_set_with(world: *ecs_world_t, component: ecs_id_t) ecs_entity_t;

/// Get the component set with ecs_set_with(). This operation returns the component that
/// was previously provided to ecs_set_with().
pub extern fn ecs_get_with(world: *const ecs_world_t) ecs_id_t;

/// Enable or disable a component. Enabling or disabling a component does not add or
/// remove a component from an entity, but prevents it from being matched with queries.
/// This operation can be useful when a component must be temporarily disabled without
/// destroying its value. It is also a more performant operation for when an application
/// needs to add/remove components at high frequency, as enabling/disabling is cheaper
/// than a regular add or remove.
pub extern fn ecs_enable_id(world: *ecs_world_t, entity: ecs_entity_t, component: ecs_id_t, enable: bool) void;

/// Test if a component is enabled. Test whether a component is currently enabled or
/// disabled. This operation will return true when the entity has the component and if
/// it has not been disabled by ecs_enable_id().
pub extern fn ecs_is_enabled_id(world: *const ecs_world_t, entity: ecs_entity_t, component: ecs_id_t) bool;

/// Create a component ref. A ref is a handle to an entity and component pair, which
/// caches a small amount of data to reduce the overhead of repeatedly accessing the
/// component. Use ecs_ref_get() to get the component data.
pub extern fn ecs_ref_init_id(world: *const ecs_world_t, entity: ecs_entity_t, component: ecs_id_t) ecs_ref_t;

/// Read a component through a ref, refreshing the ref if the entity has moved table
/// since it was made. `component` must be the one the ref was created with.
pub extern fn ecs_ref_get_id(world: *const ecs_world_t, ref: *ecs_ref_t, component: ecs_id_t) ?*anyopaque;

/// Same as `ecs_ref_get_id`, but only refreshes the ref and hands nothing back.
pub extern fn ecs_ref_update(world: *const ecs_world_t, ref: *ecs_ref_t, component: ecs_id_t) void;

/// Like `ecs_ensure_id`, but the returned storage is not constructed, so a value can be
/// built in place. A null `is_new` asserts if the component is already there; a non-null
/// one reports whether the storage is fresh, and when it says so the caller must
/// construct it — leaving it alone is undefined behaviour.
pub extern fn ecs_emplace_id(world: *ecs_world_t, entity: ecs_entity_t, component: ecs_id_t, size: usize, is_new: ?*bool) ?*anyopaque;

/// Remove the generation from an entity ID.
pub extern fn ecs_strip_generation(e: ecs_entity_t) ecs_id_t;

/// Ensure an ID is alive. This operation ensures that the provided ID is alive. This is
/// useful in scenarios where an application has an existing ID that has not been
/// created with ecs_new_w() (such as a global constant or an ID from a remote
/// application).
pub extern fn ecs_make_alive(world: *ecs_world_t, entity: ecs_entity_t) void;

/// Same as ecs_make_alive(), but for components. An ID can be an entity or a pair, and
/// can contain ID flags. This operation ensures that the entity (or entities, for a
/// pair) are alive.
pub extern fn ecs_make_alive_id(world: *ecs_world_t, component: ecs_id_t) void;

/// Override the generation of an entity. The generation count of an entity is increased
/// each time an entity is deleted and is used to test whether an entity ID is alive.
pub extern fn ecs_set_version(world: *ecs_world_t, entity: ecs_entity_t) void;

/// Get the generation of an entity.
pub extern fn ecs_get_version(entity: ecs_entity_t) u32;

/// The ids an entity holds, borrowed from its table. Null if the entity has none.
pub extern fn ecs_get_type(world: *const ecs_world_t, entity: ecs_entity_t) ?*const ecs_type_t;

/// The table an entity lives in. Null if it has no components.
pub extern fn ecs_get_table(world: *const ecs_world_t, entity: ecs_entity_t) ?*ecs_table_t;

/// Render a type as a comma-separated id list. A null type gives an empty string rather
/// than null. Free the result with `ecs_os_free`.
pub extern fn ecs_type_str(world: *const ecs_world_t, @"type": ?*const ecs_type_t) ?[*:0]u8;

/// Same as `ecs_type_str` on the table's own type, except that a null table gives null.
/// Free the result with `ecs_os_free`.
pub extern fn ecs_table_str(world: *const ecs_world_t, table: ?*const ecs_table_t) ?[*:0]u8;

/// An entity's path followed by its type, which is `ecs_get_path` and `ecs_type_str`
/// joined. Free the result with `ecs_os_free`.
pub extern fn ecs_entity_str(world: *const ecs_world_t, entity: ecs_entity_t) ?[*:0]u8;

/// The `index`th target of `rel` on this entity, counting from 0, or 0 if it has fewer.
pub extern fn ecs_get_target(world: *const ecs_world_t, entity: ecs_entity_t, rel: ecs_entity_t, index: i32) ecs_entity_t;

pub extern fn ecs_get_parent(world: *const ecs_world_t, entity: ecs_entity_t) ecs_entity_t;

pub extern fn ecs_get_name(world: *const ecs_world_t, entity: ecs_entity_t) ?[*:0]const u8;

/// Name an entity. A null name removes the name it had; entity 0 creates a new entity
/// with this name and returns it, so this returns an entity at all.
pub extern fn ecs_set_name(world: *ecs_world_t, entity: ecs_entity_t, name: ?[*:0]const u8) ecs_entity_t;

pub extern fn ecs_lookup(world: *const ecs_world_t, path: [*:0]const u8) ecs_entity_t;

/// Find or create a child of `parent` by name, using the non-fragmenting `EcsParent`
/// component rather than a `ChildOf` pair. A null name always creates.
pub extern fn ecs_new_w_parent(world: *ecs_world_t, parent: ecs_entity_t, name: ?[*:0]const u8) ecs_entity_t;

/// Walk `rel` upwards until an entity holding `component` turns up, and return it. The
/// entity itself counts, so this returns `entity` when it holds the component directly.
/// 0 if neither it nor anything above it does.
pub extern fn ecs_get_target_for_id(world: *const ecs_world_t, entity: ecs_entity_t, rel: ecs_entity_t, component: ecs_id_t) ecs_entity_t;

/// Return the depth for an entity in the tree for the specified relationship. Depth is
/// determined by counting the number of targets encountered while traversing up the
/// relationship tree for `rel`. Only acyclic relationships are supported.
pub extern fn ecs_get_depth(world: *const ecs_world_t, entity: ecs_entity_t, rel: ecs_entity_t) i32;

/// How many entities hold an id. Walks every matching table, so it is a count, not a
/// lookup.
pub extern fn ecs_count_id(world: *const ecs_world_t, entity: ecs_id_t) i32;

/// The entity's symbol — the `(EcsIdentifier, EcsSymbol)` pair, which is a second name
/// with its own index and no hierarchy. Null if it has none.
pub extern fn ecs_get_symbol(world: *const ecs_world_t, entity: ecs_entity_t) ?[*:0]const u8;

/// Set or overwrite an entity's symbol. Entity 0 creates a new entity to hold it.
pub extern fn ecs_set_symbol(world: *ecs_world_t, entity: ecs_entity_t, symbol: ?[*:0]const u8) ecs_entity_t;

/// Set an alias for an entity. An entity can be looked up using its alias from the root
/// scope without providing the fully qualified name of its parent. An entity can only
/// have a single alias.
pub extern fn ecs_set_alias(world: *ecs_world_t, entity: ecs_entity_t, alias: ?[*:0]const u8) void;

/// Find a direct child of `parent` by name, without walking a path. Parent 0 means the
/// root. Returns 0 if there is no such child.
pub extern fn ecs_lookup_child(world: *const ecs_world_t, parent: ecs_entity_t, name: [*:0]const u8) ecs_entity_t;

/// Look up an entity by path, relative to `parent`. A null `sep` means `"."`; a path that
/// opens with `prefix` is resolved from the root instead. With `recursive`, a miss walks
/// up to the parent's parent and on to the root, then tries each scope in the lookup path.
/// A null path is not an error — it yields 0.
pub extern fn ecs_lookup_path_w_sep(world: *const ecs_world_t, parent: ecs_entity_t, path: ?[*:0]const u8, sep: ?[*:0]const u8, prefix: ?[*:0]const u8, recursive: bool) ecs_entity_t;

/// Look up an entity by its symbol name. This looks up an entity by the symbol stored
/// in `(EcsIdentifier, EcsSymbol)`. The operation does not take into account
/// hierarchies.
pub extern fn ecs_lookup_symbol(world: *const ecs_world_t, symbol: ?[*:0]const u8, lookup_as_path: bool, recursive: bool) ecs_entity_t;

/// The names from `parent` down to `child`, joined by `sep` and led by `prefix`. Parent 0
/// makes the path relative to the root. Free the result with `ecs_os_free`.
pub extern fn ecs_get_path_w_sep(world: *const ecs_world_t, parent: ecs_entity_t, child: ecs_entity_t, sep: ?[*:0]const u8, prefix: ?[*:0]const u8) ?[*:0]u8;

/// Write a path identifier to a buffer. Same as ecs_get_path_w_sep(), but writes the
/// result to an `ecs_strbuf_t`.
pub extern fn ecs_get_path_w_sep_buf(world: *const ecs_world_t, parent: ecs_entity_t, child: ecs_entity_t, sep: ?[*:0]const u8, prefix: ?[*:0]const u8, buf: *ecs_strbuf_t, escape: bool) void;

/// Find or create an entity from a path. This operation will find or create an entity
/// from a path, and will create any intermediate entities if required. If the entity
/// already exists, no entities will be created.
pub extern fn ecs_new_from_path_w_sep(world: *ecs_world_t, parent: ecs_entity_t, path: ?[*:0]const u8, sep: ?[*:0]const u8, prefix: ?[*:0]const u8) ecs_entity_t;

/// Add a specified path to an entity. This operation is similar to ecs_new_from_path(),
/// but will instead add the path to an existing entity.
pub extern fn ecs_add_path_w_sep(world: *ecs_world_t, entity: ecs_entity_t, parent: ecs_entity_t, path: ?[*:0]const u8, sep: ?[*:0]const u8, prefix: ?[*:0]const u8) ecs_entity_t;

pub extern fn ecs_set_scope(world: *ecs_world_t, scope: ecs_entity_t) ecs_entity_t;

/// Get the current scope. Get the scope set by ecs_set_scope(). If no scope is set,
/// this operation will return 0.
pub extern fn ecs_get_scope(world: *const ecs_world_t) ecs_entity_t;

/// A prefix that `ECS_COMPONENT` strips off C type names before registering them, so a C
/// type `EcsPosition` can be the entity `Position`. Returns the previous prefix; flecs
/// keeps the pointer rather than a copy.
pub extern fn ecs_set_name_prefix(world: *ecs_world_t, prefix: ?[*:0]const u8) ?[*:0]const u8;

/// Set the scopes lookups search, as a 0-terminated array evaluated from the last element
/// backwards. flecs does not copy it: the array must outlive its use as the search path.
/// The default includes `EcsFlecsCore`, and a custom path replaces rather than extends it,
/// so a path without `EcsFlecsCore` breaks unqualified lookups of built-in names. Returns
/// the previous path, which is the one to put back.
pub extern fn ecs_set_lookup_path(world: *ecs_world_t, lookup_path: ?[*:0]const ecs_entity_t) ?[*:0]ecs_entity_t;

/// The search path currently in force. See `ecs_set_lookup_path`.
pub extern fn ecs_get_lookup_path(world: *const ecs_world_t) ?[*:0]ecs_entity_t;

/// Get the type info for a component. This function returns the type information for a
/// component. The component can be a regular component or a pair. For the rules on how
/// type information is determined based on a component ID, see ecs_get_typeid().
pub extern fn ecs_get_type_info(world: *const ecs_world_t, component: ecs_id_t) ?*const ecs_type_info_t;

/// Register the callbacks flecs runs when a component is constructed, copied, moved,
/// destructed, added, removed or set. Only settable while the component is still unused;
/// once it has been added to an entity the hooks are fixed.
pub extern fn ecs_set_hooks_id(world: *ecs_world_t, component: ecs_entity_t, hooks: *const ecs_type_hooks_t) void;

/// Get hooks for a component.
pub extern fn ecs_get_hooks_id(world: *const ecs_world_t, component: ecs_entity_t) ?*const ecs_type_hooks_t;

/// Return whether a specified component is a tag. This operation returns whether the
/// specified component is a tag (a component without data or size).
pub extern fn ecs_id_is_tag(world: *const ecs_world_t, component: ecs_id_t) bool;

/// Return whether a specified component is in use. This operation returns whether a
/// component is in use in the world. A component is in use if it has been added to one
/// or more tables.
pub extern fn ecs_id_in_use(world: *const ecs_world_t, component: ecs_id_t) bool;

/// Get the type for a component. This operation returns the type for a component ID, if
/// the ID is associated with a type. For a regular component with a non-zero size (an
/// entity with the EcsComponent component), the operation will return the component ID
/// itself.
pub extern fn ecs_get_typeid(world: *const ecs_world_t, component: ecs_id_t) ecs_entity_t;

/// Utility to match a component with a pattern. This operation returns true if the
/// provided pattern matches the provided component. The pattern may contain a wildcard
/// (or wildcards, when a pair).
pub extern fn ecs_id_match(component: ecs_id_t, pattern: ecs_id_t) bool;

/// Utility to check if a component is a wildcard.
pub extern fn ecs_id_is_wildcard(component: ecs_id_t) bool;

/// Utility to check if a component is an any wildcard.
pub extern fn ecs_id_is_any(component: ecs_id_t) bool;

/// Whether an id can be added to an entity. A wildcard, a dead entity, and 0 anywhere in
/// the id all make it invalid. Removal is looser: it accepts wildcards.
pub extern fn ecs_id_is_valid(world: *const ecs_world_t, component: ecs_id_t) bool;

/// Get flags associated with an ID. This operation returns the internal flags (see
/// api_flags.h) that are associated with the provided ID.
pub extern fn ecs_id_get_flags(world: *const ecs_world_t, component: ecs_id_t) ecs_flags32_t;

/// The name of an id flag — `PAIR`, `TOGGLE` or `AUTO_OVERRIDE` — or null if the value is
/// not one. Static storage, not a copy, so do not free it.
pub extern fn ecs_id_flag_str(component_flags: u64) ?[*:0]const u8;

/// Write a component string to a buffer. Same as ecs_id_str(), but writes the result to
/// ecs_strbuf_t.
pub extern fn ecs_id_str_buf(world: *const ecs_world_t, component: ecs_id_t, buf: *ecs_strbuf_t) void;

/// The reverse of `ecs_id_str`. Returns 0 if the string does not parse. Needs the query
/// DSL addon — flecs's own doc names the script addon here, but the implementation is
/// guarded on `FLECS_QUERY_DSL`, which script does not imply.
pub extern fn ecs_id_from_str(world: *const ecs_world_t, expr: [*:0]const u8) ecs_id_t;
