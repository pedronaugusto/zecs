//! flecs C declarations for the world, its lifecycle, and modules.
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
pub const ecs_build_info_t = core.ecs_build_info_t;
pub const ecs_component_desc_t = core.ecs_component_desc_t;
pub const ecs_ctx_free_t = core.ecs_ctx_free_t;
pub const ecs_entity_range_t = core.ecs_entity_range_t;
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_fini_action_t = core.ecs_fini_action_t;
pub const ecs_flags32_t = core.ecs_flags32_t;
pub const ecs_ftime_t = core.ecs_ftime_t;
pub const ecs_id_t = core.ecs_id_t;
pub const ecs_module_action_t = core.ecs_module_action_t;
pub const ecs_poly_t = core.ecs_poly_t;
pub const ecs_world_info_t = core.ecs_world_info_t;
pub const ecs_world_t = core.ecs_world_t;

pub extern fn ecs_init() ?*ecs_world_t;

pub extern fn ecs_mini() ?*ecs_world_t;

pub extern fn ecs_fini(world: *ecs_world_t) c_int;

pub extern fn ecs_is_fini(world: *const ecs_world_t) bool;

pub extern fn ecs_progress(world: *ecs_world_t, delta_time: ecs_ftime_t) bool;

pub extern fn ecs_frame_begin(world: *ecs_world_t, delta_time: ecs_ftime_t) ecs_ftime_t;

pub extern fn ecs_frame_end(world: *ecs_world_t) void;

pub extern fn ecs_quit(world: *ecs_world_t) void;

pub extern fn ecs_should_quit(world: *const ecs_world_t) bool;

pub extern fn ecs_set_target_fps(world: *ecs_world_t, fps: ecs_ftime_t) void;

pub extern fn ecs_set_threads(world: *ecs_world_t, threads: i32) void;

pub extern fn ecs_set_task_threads(world: *ecs_world_t, task_threads: i32) void;

pub extern fn ecs_get_stage_count(world: *const ecs_world_t) i32;

pub extern fn ecs_defer_begin(world: *ecs_world_t) bool;

pub extern fn ecs_defer_end(world: *ecs_world_t) bool;

pub extern fn ecs_is_deferred(world: *const ecs_world_t) bool;

pub extern fn ecs_set_ctx(world: *ecs_world_t, ctx: ?*anyopaque, ctx_free: ecs_ctx_free_t) void;

pub extern fn ecs_get_ctx(world: *const ecs_world_t) ?*anyopaque;

/// Same as `ecs_init`, but reads the command line. flecs uses it to derive the
/// application name from `argv[0]`.
pub extern fn ecs_init_w_args(argc: c_int, argv: ?[*]?[*:0]u8) ?*ecs_world_t;

/// Register an action to be executed when the world is destroyed. Fini actions are
/// typically used when a module needs to clean up before the world shuts down.
pub extern fn ecs_atfini(world: *ecs_world_t, action: ecs_fini_action_t, ctx: ?*anyopaque) void;

/// A borrowed run of entity ids, `ids[0..count]`, alive ones first: `ids[0..alive_count]`
/// are alive and `ids[alive_count..count]` are dead ids waiting to be recycled. flecs.h's
/// own example starts the second loop at `alive_count + 1` and so skips one — the index
/// it reserves is already skipped by the time the pointer reaches here.
///
/// Points into flecs's own storage: read-only, never freed, and invalidated by the next
/// entity created or deleted.
pub const ecs_entities_t = extern struct {
    ids: ?[*]const ecs_entity_t = null,
    count: i32 = 0,
    alive_count: i32 = 0,
};

/// Every entity id in the world, alive and recycled.
pub extern fn ecs_get_entities(world: *const ecs_world_t) ecs_entities_t;

/// The world's internal state flags. flecs does not export names for the bits, so this is
/// only useful next to a copy of its sources.
pub extern fn ecs_world_get_flags(world: *const ecs_world_t) ecs_flags32_t;

/// Register an action to be executed once after the frame. Post frame actions are
/// typically used for calling operations that cannot be invoked during iteration, such
/// as changing the number of threads.
pub extern fn ecs_run_post_frame(world: *ecs_world_t, action: ecs_fini_action_t, ctx: ?*anyopaque) void;

/// Start or stop timing whole frames, and the share of each spent in systems and in
/// merges. The totals land in `ecs_world_info_t`.
pub extern fn ecs_measure_frame_time(world: *ecs_world_t, enable: bool) void;

/// Start or stop timing individual systems. Costs a clock read per system per frame.
pub extern fn ecs_measure_system_time(world: *ecs_world_t, enable: bool) void;

/// Set flags that every `ecs_query_desc_t` in this world gets on top of its own — most
/// usefully `EcsQueryMatchEmptyTables`, `EcsQueryMatchDisabled` or `EcsQueryMatchPrefab`.
pub extern fn ecs_set_default_query_flags(world: *ecs_world_t, flags: ecs_flags32_t) void;

/// Enter readonly mode, where mutations are queued rather than applied. It is what lets
/// flecs assume the shape of the world holds still while systems run, and what turns an
/// accidental write from another thread into a diagnosable error.
pub extern fn ecs_readonly_begin(world: *ecs_world_t, multi_threaded: bool) bool;

/// Leave readonly mode and flush everything that was deferred while in it.
pub extern fn ecs_readonly_end(world: *ecs_world_t) void;

/// Flush one stage's queued commands into the world. Takes the stage pointer, which flecs
/// spells as a world.
pub extern fn ecs_merge(stage: *ecs_world_t) void;

/// Suspend deferring but do not flush queue. This operation can be used to do an
/// undeferred operation while not flushing the operations in the queue.
pub extern fn ecs_defer_suspend(world: *ecs_world_t) void;

/// Resume deferring. See ecs_defer_suspend().
pub extern fn ecs_defer_resume(world: *ecs_world_t) void;

/// Test if deferring is suspended for the current stage.
pub extern fn ecs_is_defer_suspended(world: *const ecs_world_t) bool;

/// Configure the world to have N stages. This initializes N stages, which allows
/// applications to defer operations to multiple isolated defer queues. This is
/// typically used for applications with multiple threads, where each thread gets its
/// own queue, and commands are merged when threads are synchronized.
pub extern fn ecs_set_stage_count(world: *ecs_world_t, stages: i32) void;

/// One of the world's stages, typed as a world because that is what every operation
/// takes. A thread with its own stage can call the API without racing the others.
pub extern fn ecs_get_stage(world: *const ecs_world_t, stage_id: i32) ?*ecs_world_t;

/// Whether this world or stage refuses writes at the moment.
pub extern fn ecs_stage_is_readonly(world: *const ecs_world_t) bool;

/// Create an unmanaged stage. Create a stage whose lifecycle is not managed by the
/// world. Must be freed with ecs_stage_free().
pub extern fn ecs_stage_new(world: *ecs_world_t) ?*ecs_world_t;

/// Free an unmanaged stage.
pub extern fn ecs_stage_free(stage: *ecs_world_t) void;

/// Get the stage ID. The stage ID can be used by an application to learn about which
/// stage it is using, which typically corresponds with the worker thread ID.
pub extern fn ecs_stage_get_id(world: *const ecs_world_t) i32;

/// Set a world binding context. Same as ecs_set_ctx(), but for binding context. A
/// binding context is intended specifically for language bindings to store
/// binding-specific data.
pub extern fn ecs_set_binding_ctx(world: *ecs_world_t, ctx: ?*anyopaque, ctx_free: ecs_ctx_free_t) void;

pub extern fn ecs_get_binding_ctx(world: *const ecs_world_t) ?*anyopaque;

/// The addons, flags and version this flecs was built with. Static, so it needs no world
/// and outlives every world.
pub extern fn ecs_get_build_info() *const ecs_build_info_t;

/// The world's counters and timings. Borrowed and live: the fields keep changing under
/// the pointer as the world runs.
pub extern fn ecs_get_world_info(world: *const ecs_world_t) *const ecs_world_info_t;

/// Dimension the world for a specified number of entities. This operation will
/// preallocate memory in the world for the specified number of entities. Specifying a
/// number lower than the current number of entities in the world will have no effect.
pub extern fn ecs_dim(world: *ecs_world_t, entity_count: i32) void;

/// Return memory the world no longer uses: unused pages of the entity index, component
/// columns, empty tables. flecs's internal pools are left alone, so the figure the OS
/// reports may not move unless the build also has `FLECS_USE_OS_ALLOC`.
pub extern fn ecs_shrink(world: *ecs_world_t) void;

/// Create a new entity range. This function creates a range that constrains new entity
/// identifiers returned by the specified [min, max] interval. Each range maintains its
/// own list of recycled entity ids, which ensures that recycled ids always respect the
/// configured range. If `max` is set to 0, the range is unbounded.
pub extern fn ecs_entity_range_new(world: *ecs_world_t, min: u32, max: u32) ?*const ecs_entity_range_t;

/// Activate a range created with `ecs_entity_range_new`. From then on new ids, recycled
/// ones included, fall inside its `[min, max]`.
pub extern fn ecs_entity_range_set(world: *ecs_world_t, range: *const ecs_entity_range_t) void;

/// Get the currently active entity id range. Returns the range set by
/// ecs_entity_range_set(), or NULL if no range is active.
pub extern fn ecs_entity_range_get(world: *const ecs_world_t) ?*const ecs_entity_range_t;

/// Get the largest issued entity ID (not counting generation).
pub extern fn ecs_get_max_id(world: *const ecs_world_t) ecs_entity_t;

/// Do now the housekeeping flecs would otherwise put off until something needs it. Mostly
/// of use to a test that wants the side effects, such as a delayed event, to land at a
/// predictable point. Zero flags does the component monitors only, not everything.
pub extern fn ecs_run_aperiodic(world: *ecs_world_t, flags: ecs_flags32_t) void;

pub const ecs_delete_empty_tables_desc_t = extern struct {
    clear_generation: u16 = 0,
    delete_generation: u16 = 0,
    time_budget_seconds: f64 = 0,
    offset: i32 = 0,
};

/// Delete tables that have stayed empty for long enough, and return how many went. Empty
/// tables cost nothing to iterate, so this is a memory measure — worth it in a world with
/// many components, where the number of possible tables grows fast.
pub extern fn ecs_delete_empty_tables(world: *ecs_world_t, desc: *const ecs_delete_empty_tables_desc_t) i32;

/// The world behind a flecs object — a world, a stage, a query, an observer. Given a
/// stage it returns the world the stage belongs to, which is how flecs turns a stage
/// pointer back into something it can read from.
pub extern fn ecs_get_world(poly: *const ecs_poly_t) ?*const ecs_world_t;

/// The entity a flecs object is registered as, if it has one.
pub extern fn ecs_get_entity(poly: *const ecs_poly_t) ecs_entity_t;

/// Whether a flecs object is of the given kind. `type` is the kind's magic number — the
/// `ecs_world_t_magic` family — not an entity, and flecs.h has no non-macro name for it.
pub extern fn flecs_poly_is_(object: *const ecs_poly_t, @"type": i32) bool;

pub extern fn ecs_make_pair(first: ecs_entity_t, second: ecs_entity_t) ecs_id_t;

pub extern fn ecs_id_is_pair(id: ecs_id_t) bool;

/// Begin exclusive thread access. This operation ensures that only the thread from
/// which this operation is called can access the world. Attempts to access the world
/// from other threads will panic.
pub extern fn ecs_exclusive_access_begin(world: *ecs_world_t, thread_name: ?[*:0]const u8) void;

/// End exclusive thread access. This operation should be called after
/// ecs_exclusive_access_begin(). After calling this operation, other threads are no
/// longer prevented from mutating the world.
pub extern fn ecs_exclusive_access_end(world: *ecs_world_t, lock_world: bool) void;

/// Import a module, running its action unless the name already resolves, which is how a
/// second import is skipped. Everything the module defines becomes a child of the module
/// entity, so two modules cannot collide on a name. `module` must not be null. 0 if the
/// action ran without defining the module entity.
pub extern fn ecs_import(world: *ecs_world_t, module: ecs_module_action_t, module_name: ?[*:0]const u8) ecs_entity_t;

/// Same as `ecs_import`, converting a PascalCase C identifier to a scoped name first.
/// This is what flecs's `ECS_IMPORT` macro calls.
pub extern fn ecs_import_c(world: *ecs_world_t, module: ecs_module_action_t, module_name_c: ?[*:0]const u8) ecs_entity_t;

/// Import a module out of a dynamic library. One library can hold several modules, which
/// is why both names are given; a null `module_name` derives one from the library name.
/// The library name is canonical — `flecs.components.transform` — and the OS API's
/// `module_to_dl` callback turns it into a platform filename, so override that when the
/// default naming does not match. 0 if the library or the module could not be loaded.
pub extern fn ecs_import_from_library(world: *ecs_world_t, library_name: [*:0]const u8, module_name: ?[*:0]const u8) ecs_entity_t;

/// Register the module entity itself, which is what a module's own import action calls
/// first. `c_name` is the PascalCase identifier, converted to a scoped name and also set
/// as the entity's symbol.
pub extern fn ecs_module_init(world: *ecs_world_t, c_name: [*:0]const u8, desc: *const ecs_component_desc_t) ecs_entity_t;
