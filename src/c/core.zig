//! flecs C declarations for the scalars, containers, allocator seam, core API types and constants everything else here is built from.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const abi = @import("abi.zig");
const flecs_debug = options.debug_checks == .debug or options.debug_checks == .sanitize;
const flecs_sanitize = options.debug_checks == .sanitize;

pub const ecs_flags8_t = u8;

pub const ecs_flags16_t = u16;

pub const ecs_flags32_t = u32;

pub const ecs_flags64_t = u64;

/// Maximum terms in a query. Sizes `ecs_query_desc_t`, so it is part of the ABI.
pub const FLECS_TERM_COUNT_MAX = options.term_count_max;

/// Maximum events in an observer. Sizes `ecs_observer_desc_t`.
pub const FLECS_EVENT_DESC_MAX = options.event_desc_max;

/// Maximum ids in `ecs_bulk_desc_t`.
pub const FLECS_ID_DESC_MAX = options.id_desc_max;

/// Like `ecs_block_allocator_t`, this collapses to a stub under `FLECS_USE_OS_ALLOC`:
/// with the OS allocator in charge there are no pools to keep.
pub const ecs_allocator_t = if (options.use_os_alloc) extern struct {
    dummy: bool = false,
} else extern struct {
    chunks: ecs_block_allocator_t = .{},
    sizes: ecs_sparse_t = .{},
};

/// flecs writes this as `(0xFFull << 60)`, where the top four bits shift out of a
/// 64-bit value. The result is the top nibble; the ABI test checks it against the header.
pub const ECS_ID_FLAGS_MASK: ecs_id_t = 0xF000_0000_0000_0000;

pub const ECS_ENTITY_MASK: ecs_id_t = 0xFFFFFFFF;

pub const ECS_GENERATION_MASK: ecs_id_t = 0xFFFF << 32;

pub const ECS_COMPONENT_MASK: ecs_id_t = ~ECS_ID_FLAGS_MASK;

/// `ecs_float_t` is a macro in flecs, set from the build. The two sides read the same
/// option, and the ABI probe asserts they agree.
pub const ecs_float_t = if (options.float_is_f64) f64 else f32;

pub const ecs_ftime_t = if (options.ftime_is_f64) f64 else f32;

pub const ecs_id_t = u64;

pub const ecs_entity_t = ecs_id_t;

pub const ecs_size_t = i32;

/// The ids of one table, as `array[0..count]`. Sorted, so a type is comparable.
pub const ecs_type_t = extern struct {
    array: ?[*]ecs_id_t = null,
    count: i32 = 0,
};

pub const ecs_world_t = opaque {};

pub const ecs_stage_t = opaque {};

pub const ecs_table_t = opaque {};

pub const ecs_mixins_t = opaque {};

pub const ecs_observable_t = opaque {};

pub const ecs_component_record_t = opaque {};

pub const ecs_term_t = extern struct {
    id: ecs_id_t = 0,
    src: ecs_term_ref_t = .{},
    first: ecs_term_ref_t = .{},
    second: ecs_term_ref_t = .{},
    trav: ecs_entity_t = 0,
    inout: i16 = 0,
    oper: i16 = 0,
    field_index: i8 = 0,
    flags_: ecs_flags16_t = 0,
};

/// The query object itself. flecs defines it in the header rather than keeping it
/// opaque, because iteration reads `field_count` and the termsets straight off it.
pub const ecs_query_t = extern struct {
    hdr: ecs_header_t = .{},
    terms: ?[*]ecs_term_t = null,
    sizes: ?[*]i32 = null,
    ids: ?[*]ecs_id_t = null,
    bloom_filter: u64 = 0,
    flags: ecs_flags32_t = 0,
    var_count: i8 = 0,
    term_count: i8 = 0,
    field_count: i8 = 0,
    fixed_fields: ecs_termset_t = 0,
    var_fields: ecs_termset_t = 0,
    static_id_fields: ecs_termset_t = 0,
    data_fields: ecs_termset_t = 0,
    write_fields: ecs_termset_t = 0,
    read_fields: ecs_termset_t = 0,
    row_fields: ecs_termset_t = 0,
    shared_readonly_fields: ecs_termset_t = 0,
    set_fields: ecs_termset_t = 0,
    cache_kind: ecs_query_cache_kind_t = 0,
    vars: ?[*]?[*:0]u8 = null,
    ctx: ?*anyopaque = null,
    binding_ctx: ?*anyopaque = null,
    entity: ecs_entity_t = 0,
    real_world: ?*ecs_world_t = null,
    world: ?*ecs_world_t = null,
    eval_count: i32 = 0,
};

/// The observer object. Like `ecs_query_t`, flecs defines it rather than hiding it.
pub const ecs_observer_t = extern struct {
    hdr: ecs_header_t = .{},
    query: ?*ecs_query_t = null,
    events: [FLECS_EVENT_DESC_MAX]ecs_entity_t = @splat(0),
    event_count: i32 = 0,
    callback: ecs_iter_action_t = null,
    run: ecs_run_action_t = null,
    ctx: ?*anyopaque = null,
    callback_ctx: ?*anyopaque = null,
    run_ctx: ?*anyopaque = null,
    ctx_free: ecs_ctx_free_t = null,
    callback_ctx_free: ecs_ctx_free_t = null,
    run_ctx_free: ecs_ctx_free_t = null,
    observable: ?*ecs_observable_t = null,
    world: ?*ecs_world_t = null,
    entity: ecs_entity_t = 0,
};

pub const ecs_iter_t = extern struct {
    world: ?*ecs_world_t = null,
    real_world: ?*ecs_world_t = null,
    offset: i32 = 0,
    count: i32 = 0,
    entities: ?[*]const ecs_entity_t = null,
    ptrs: ?[*]?*anyopaque = null,
    trs: ?[*]const ?*const ecs_table_record_t = null,
    columns: ?[*]const i16 = null,
    sizes: ?[*]const ecs_size_t = null,
    table: ?*ecs_table_t = null,
    other_table: ?*ecs_table_t = null,
    ids: ?[*]ecs_id_t = null,
    sources: ?[*]ecs_entity_t = null,
    constrained_vars: ecs_flags64_t = 0,
    set_fields: ecs_termset_t = 0,
    ref_fields: ecs_termset_t = 0,
    row_fields: ecs_termset_t = 0,
    up_fields: ecs_termset_t = 0,
    system: ecs_entity_t = 0,
    event: ecs_entity_t = 0,
    event_id: ecs_id_t = 0,
    event_cur: i32 = 0,
    field_count: i8 = 0,
    term_index: i8 = 0,
    query: ?*const ecs_query_t = null,
    param: ?*anyopaque = null,
    ctx: ?*anyopaque = null,
    binding_ctx: ?*anyopaque = null,
    callback_ctx: ?*anyopaque = null,
    run_ctx: ?*anyopaque = null,
    delta_time: ecs_ftime_t = 0,
    delta_system_time: ecs_ftime_t = 0,
    frame_offset: i32 = 0,
    flags: ecs_flags32_t = 0,
    interrupted_by: ecs_entity_t = 0,
    priv_: ecs_iter_private_t = .{},
    next: ecs_iter_next_action_t = null,
    callback: ecs_iter_action_t = null,
    fini: ecs_iter_fini_action_t = null,
    chain_it: ?*ecs_iter_t = null,
};

/// A cached handle to one entity's component, for reading the same pair over and over.
/// flecs measures it at three to five times the speed of `ecs_get_id`.
///
/// flecs gives this struct extra fields under `FLECS_DEBUG`, so it is a different size in a
/// checked build than in a shipping one. Both are spelled out rather than assembled
/// at comptime: this file exists to read like the C it mirrors.
pub const ecs_ref_t = if (flecs_debug) extern struct {
    entity: ecs_entity_t = 0,
    table_id: u64 = 0,
    table_version_fast: u32 = 0,
    table_version: u16 = 0,
    ptr: ?*anyopaque = null,
    id: ecs_entity_t = 0,
} else extern struct {
    entity: ecs_entity_t = 0,
    table_id: u64 = 0,
    table_version_fast: u32 = 0,
    table_version: u16 = 0,
    ptr: ?*anyopaque = null,
};

pub const ecs_type_hooks_t = extern struct {
    ctor: ecs_xtor_t = null,
    dtor: ecs_xtor_t = null,
    copy: ecs_copy_t = null,
    move: ecs_move_t = null,
    copy_ctor: ecs_copy_t = null,
    move_ctor: ecs_move_t = null,
    ctor_move_dtor: ecs_move_t = null,
    move_dtor: ecs_move_t = null,
    cmp: ecs_cmp_t = null,
    equals: ecs_equals_t = null,
    flags: ecs_flags32_t = 0,
    on_add: ecs_iter_action_t = null,
    on_set: ecs_iter_action_t = null,
    on_remove: ecs_iter_action_t = null,
    on_replace: ecs_iter_action_t = null,
    ctx: ?*anyopaque = null,
    binding_ctx: ?*anyopaque = null,
    lifecycle_ctx: ?*anyopaque = null,
    ctx_free: ecs_ctx_free_t = null,
    binding_ctx_free: ecs_ctx_free_t = null,
    lifecycle_ctx_free: ecs_ctx_free_t = null,
};

pub const ecs_type_info_t = extern struct {
    size: ecs_size_t = 0,
    alignment: ecs_size_t = 0,
    hooks: ecs_type_hooks_t = .{},
    component: ecs_entity_t = 0,
    name: ?[*:0]const u8 = null,
};

/// Where an entity lives: which table, and which row of it.
pub const ecs_record_t = extern struct {
    table: ?*ecs_table_t = null,
    row: u32 = 0,
    dense: i32 = 0,
};

pub const ecs_poly_t = anyopaque;

pub const ecs_header_t = extern struct {
    type: i32 = 0,
    refcount: i32 = 0,
    mixins: ?*ecs_mixins_t = null,
};

/// Where a component sits within one table: its column, and how many of it there are.
pub const ecs_table_record_t = extern struct {
    hdr: ecs_table_cache_hdr_t = .{},
    index: i16 = 0,
    count: i16 = 0,
    column: i16 = 0,
};

/// flecs gives this struct extra fields under `FLECS_SANITIZE`, so it is a different size in a
/// checked build than in a shipping one. Both are spelled out rather than assembled
/// at comptime: this file exists to read like the C it mirrors.
pub const ecs_vec_t = if (flecs_sanitize) extern struct {
    array: ?*anyopaque = null,
    count: i32 = 0,
    size: i32 = 0,
    elem_size: ecs_size_t = 0,
    type_name: ?[*:0]const u8 = null,
} else extern struct {
    array: ?*anyopaque = null,
    count: i32 = 0,
    size: i32 = 0,
};

/// Initialize a vector.
pub extern fn ecs_vec_init(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32) void;

/// Initialize a vector with debug info.
pub extern fn ecs_vec_init_w_dbg_info(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32, type_name: ?[*:0]const u8) void;

/// Initialize a vector if it is not already initialized.
pub extern fn ecs_vec_init_if(vec: *ecs_vec_t, size: ecs_size_t) void;

/// Deinitialize a vector.
pub extern fn ecs_vec_fini(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t) void;

/// Reset a vector. Keeps allocated memory for reuse.
pub extern fn ecs_vec_reset(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t) ?*ecs_vec_t;

/// Clear a vector. Sets count to zero without freeing memory.
pub extern fn ecs_vec_clear(vec: *ecs_vec_t) void;

/// Append a new element to the vector.
pub extern fn ecs_vec_append(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t) ?*anyopaque;

/// Remove an element by swapping with the last element.
pub extern fn ecs_vec_remove(vec: *ecs_vec_t, size: ecs_size_t, elem: i32) void;

/// Remove an element while preserving order.
pub extern fn ecs_vec_remove_ordered(v: *ecs_vec_t, size: ecs_size_t, index: i32) void;

/// Remove the last element from the vector.
pub extern fn ecs_vec_remove_last(vec: *ecs_vec_t) void;

/// Copy a vector.
pub extern fn ecs_vec_copy(allocator: ?*ecs_allocator_t, vec: *const ecs_vec_t, size: ecs_size_t) ecs_vec_t;

/// Copy a vector and shrink to fit.
pub extern fn ecs_vec_copy_shrink(allocator: ?*ecs_allocator_t, vec: *const ecs_vec_t, size: ecs_size_t) ecs_vec_t;

/// Reclaim unused memory. Shrinks the vector's allocation to fit its count.
pub extern fn ecs_vec_reclaim(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t) void;

/// Set the capacity of a vector.
pub extern fn ecs_vec_set_size(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32) void;

/// Set the minimum capacity of a vector. Does not shrink.
pub extern fn ecs_vec_set_min_size(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32) void;

/// Set the minimum capacity using type info for lifecycle management.
pub extern fn ecs_vec_set_min_size_w_type_info(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32, ti: ?*const ecs_type_info_t) void;

/// Set the minimum count. Increases count if smaller than elem_count.
pub extern fn ecs_vec_set_min_count(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32) void;

/// Set the minimum count and zero-initialize new elements.
pub extern fn ecs_vec_set_min_count_zeromem(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32) void;

/// Set the element count of a vector.
pub extern fn ecs_vec_set_count(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32) void;

/// Set the element count using type info for lifecycle management.
pub extern fn ecs_vec_set_count_w_type_info(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32, ti: ?*const ecs_type_info_t) void;

/// Set the minimum count using type info for lifecycle management.
pub extern fn ecs_vec_set_min_count_w_type_info(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32, ti: ?*const ecs_type_info_t) void;

/// Grow the vector by a number of elements.
pub extern fn ecs_vec_grow(allocator: ?*ecs_allocator_t, vec: *ecs_vec_t, size: ecs_size_t, elem_count: i32) ?*anyopaque;

/// Return the number of elements in the vector.
pub extern fn ecs_vec_count(vec: *const ecs_vec_t) i32;

/// Return the allocated capacity of the vector.
pub extern fn ecs_vec_size(vec: *const ecs_vec_t) i32;

/// Get a pointer to an element at the given index.
pub extern fn ecs_vec_get(vec: *const ecs_vec_t, size: ecs_size_t, index: i32) ?*anyopaque;

/// Get a pointer to the first element.
pub extern fn ecs_vec_first(vec: *const ecs_vec_t) ?*anyopaque;

/// Get a pointer to the last element.
pub extern fn ecs_vec_last(vec: *const ecs_vec_t, size: ecs_size_t) ?*anyopaque;

/// One page of a sparse set: `sparse` maps into the dense array, `data` holds the
/// elements. Both are `FLECS_SPARSE_PAGE_SIZE` long.
pub const ecs_sparse_page_t = extern struct {
    sparse: ?[*]i32 = null,
    data: ?*anyopaque = null,
};

pub const ecs_sparse_t = extern struct {
    dense: ecs_vec_t = .{},
    pages: ecs_vec_t = .{},
    size: ecs_size_t = 0,
    count: i32 = 0,
    max_id: u64 = 0,
    allocator: ?*ecs_allocator_t = null,
    page_allocator: ?*ecs_block_allocator_t = null,
};

/// Initialize a sparse set.
pub extern fn flecs_sparse_init(result: *ecs_sparse_t, allocator: ?*ecs_allocator_t, page_allocator: ?*ecs_block_allocator_t, size: ecs_size_t) void;

/// Deinitialize a sparse set.
pub extern fn flecs_sparse_fini(sparse: *ecs_sparse_t) void;

/// Remove all elements from a sparse set.
pub extern fn flecs_sparse_clear(sparse: *ecs_sparse_t) void;

/// Add an element to a sparse set. This generates or recycles an ID.
pub extern fn flecs_sparse_add(sparse: *ecs_sparse_t, elem_size: ecs_size_t) ?*anyopaque;

/// Get the last issued ID.
pub extern fn flecs_sparse_last_id(sparse: *const ecs_sparse_t) u64;

/// Generate or recycle a new ID.
pub extern fn flecs_sparse_new_id(sparse: *ecs_sparse_t) u64;

/// Remove an element.
pub extern fn flecs_sparse_remove(sparse: *ecs_sparse_t, size: ecs_size_t, id: u64) bool;

/// Remove an element and increase the generation.
pub extern fn flecs_sparse_remove_w_gen(sparse: *ecs_sparse_t, size: ecs_size_t, id: u64) bool;

/// Test if an ID is alive, which requires the generation count to match.
pub extern fn flecs_sparse_is_alive(sparse: *const ecs_sparse_t, id: u64) bool;

/// Get a value from a sparse set by dense ID. This function is useful in combination
/// with flecs_sparse_count() for iterating all values in the set.
pub extern fn flecs_sparse_get_dense(sparse: *const ecs_sparse_t, elem_size: ecs_size_t, index: i32) ?*anyopaque;

/// Get the number of alive elements in the sparse set.
pub extern fn flecs_sparse_count(sparse: *const ecs_sparse_t) i32;

/// Check if a sparse set has an ID.
pub extern fn flecs_sparse_has(sparse: *const ecs_sparse_t, id: u64) bool;

/// Get element by sparse ID, regardless of whether the element is alive or not.
pub extern fn flecs_sparse_get(sparse: *const ecs_sparse_t, elem_size: ecs_size_t, id: u64) ?*anyopaque;

/// Create an element by (sparse) ID.
pub extern fn flecs_sparse_insert(sparse: *ecs_sparse_t, elem_size: ecs_size_t, id: u64) ?*anyopaque;

/// Get or create an element by (sparse) ID.
pub extern fn flecs_sparse_ensure(sparse: *ecs_sparse_t, elem_size: ecs_size_t, id: u64, is_new: ?*bool) ?*anyopaque;

/// Fast version of ensure with no liveness checking.
pub extern fn flecs_sparse_ensure_fast(sparse: *ecs_sparse_t, elem_size: ecs_size_t, id: u64) ?*anyopaque;

/// The dense array of ids, alive ones and dead ones together. Pair it with
/// `flecs_sparse_count`, which counts only the alive ones.
pub extern fn flecs_sparse_ids(sparse: *const ecs_sparse_t) ?[*]const u64;

/// Shrink sparse set memory to fit current usage.
pub extern fn flecs_sparse_shrink(sparse: *ecs_sparse_t) void;

/// Initialize a public sparse set.
pub extern fn ecs_sparse_init(sparse: *ecs_sparse_t, elem_size: ecs_size_t) void;

/// Add an element to a public sparse set.
pub extern fn ecs_sparse_add(sparse: *ecs_sparse_t, elem_size: ecs_size_t) ?*anyopaque;

/// Get the last issued ID from a public sparse set.
pub extern fn ecs_sparse_last_id(sparse: *const ecs_sparse_t) u64;

/// Get the number of alive elements in a public sparse set.
pub extern fn ecs_sparse_count(sparse: *const ecs_sparse_t) i32;

/// Get a value from a public sparse set by dense index.
pub extern fn ecs_sparse_get_dense(sparse: *const ecs_sparse_t, elem_size: ecs_size_t, index: i32) ?*anyopaque;

/// Get a value from a public sparse set by sparse ID.
pub extern fn ecs_sparse_get(sparse: *const ecs_sparse_t, elem_size: ecs_size_t, id: u64) ?*anyopaque;

/// Forward declaration of map type.
pub const ecs_map_t = opaque {};

pub const ecs_block_allocator_block_t = extern struct {
    memory: ?*anyopaque = null,
    next: ?*ecs_block_allocator_block_t = null,
};

pub const ecs_block_allocator_chunk_header_t = extern struct {
    next: ?*ecs_block_allocator_chunk_header_t = null,
};

/// flecs gives this struct extra fields under `FLECS_SANITIZE`, so it is a different size in a
/// checked build than in a shipping one. Both are spelled out rather than assembled
/// at comptime: this file exists to read like the C it mirrors.
/// Three shapes, not two. `FLECS_USE_OS_ALLOC` takes the block allocator out of the
/// picture entirely and leaves a stub holding only the allocation size; without it flecs
/// keeps a free list and a block list; and `FLECS_SANITIZE` adds outstanding-allocation
/// tracking on top of that. All three are real configurations of this package.
pub const ecs_block_allocator_t = if (options.use_os_alloc) extern struct {
    data_size: i32 = 0,
} else if (flecs_sanitize) extern struct {
    data_size: i32 = 0,
    chunk_size: i32 = 0,
    chunks_per_block: i32 = 0,
    block_size: i32 = 0,
    head: ?*ecs_block_allocator_chunk_header_t = null,
    block_head: ?*ecs_block_allocator_block_t = null,
    alloc_count: i32 = 0,
    outstanding: ?*ecs_map_t = null,
} else extern struct {
    data_size: i32 = 0,
    chunk_size: i32 = 0,
    chunks_per_block: i32 = 0,
    block_size: i32 = 0,
    head: ?*ecs_block_allocator_chunk_header_t = null,
    block_head: ?*ecs_block_allocator_block_t = null,
};

/// Initialize a block allocator.
pub extern fn flecs_ballocator_init(ba: *ecs_block_allocator_t, size: ecs_size_t) void;

/// Create a new block allocator on the heap.
pub extern fn flecs_ballocator_new(size: ecs_size_t) ?*ecs_block_allocator_t;

/// Deinitialize a block allocator.
pub extern fn flecs_ballocator_fini(ba: *ecs_block_allocator_t) void;

/// Free a block allocator created with flecs_ballocator_new().
pub extern fn flecs_ballocator_free(ba: *ecs_block_allocator_t) void;

/// Allocate a block of memory.
pub extern fn flecs_balloc(allocator: *ecs_block_allocator_t) ?*anyopaque;

/// Allocate a block of memory with debug type name info.
pub extern fn flecs_balloc_w_dbg_info(allocator: *ecs_block_allocator_t, type_name: ?[*:0]const u8) ?*anyopaque;

/// Allocate a zeroed block of memory.
pub extern fn flecs_bcalloc(allocator: *ecs_block_allocator_t) ?*anyopaque;

/// Allocate a zeroed block of memory with debug type name info.
pub extern fn flecs_bcalloc_w_dbg_info(allocator: *ecs_block_allocator_t, type_name: ?[*:0]const u8) ?*anyopaque;

/// Free a block of memory.
pub extern fn flecs_bfree(allocator: *ecs_block_allocator_t, memory: ?*anyopaque) void;

/// Free a block of memory with debug type name info.
pub extern fn flecs_bfree_w_dbg_info(allocator: *ecs_block_allocator_t, memory: ?*anyopaque, type_name: ?[*:0]const u8) void;

/// Reallocate a block from one block allocator to another.
pub extern fn flecs_brealloc(dst: *ecs_block_allocator_t, src: *ecs_block_allocator_t, memory: ?*anyopaque) ?*anyopaque;

/// Reallocate a block with debug type name info.
pub extern fn flecs_brealloc_w_dbg_info(dst: *ecs_block_allocator_t, src: *ecs_block_allocator_t, memory: ?*anyopaque, type_name: ?[*:0]const u8) ?*anyopaque;

/// Duplicate a block of memory.
pub extern fn flecs_bdup(ba: *ecs_block_allocator_t, memory: ?*anyopaque) ?*anyopaque;

pub const ecs_stack_page_t = extern struct {
    data: ?*anyopaque = null,
    next: ?*ecs_stack_page_t = null,
    sp: i16 = 0,
    id: u32 = 0,
};

/// flecs gives this struct extra fields under `FLECS_DEBUG`, so it is a different size in a
/// checked build than in a shipping one. Both are spelled out rather than assembled
/// at comptime: this file exists to read like the C it mirrors.
pub const ecs_stack_cursor_t = if (flecs_debug) extern struct {
    prev: ?*ecs_stack_cursor_t = null,
    page: ?*ecs_stack_page_t = null,
    sp: i16 = 0,
    is_free: bool = false,
    owner: ?*ecs_stack_t = null,
} else extern struct {
    prev: ?*ecs_stack_cursor_t = null,
    page: ?*ecs_stack_page_t = null,
    sp: i16 = 0,
    is_free: bool = false,
};

/// flecs gives this struct extra fields under `FLECS_DEBUG`, so it is a different size in a
/// checked build than in a shipping one. Both are spelled out rather than assembled
/// at comptime: this file exists to read like the C it mirrors.
pub const ecs_stack_t = if (flecs_debug) extern struct {
    first: ?*ecs_stack_page_t = null,
    tail_page: ?*ecs_stack_page_t = null,
    tail_cursor: ?*ecs_stack_cursor_t = null,
    cursor_count: i32 = 0,
} else extern struct {
    first: ?*ecs_stack_page_t = null,
    tail_page: ?*ecs_stack_page_t = null,
    tail_cursor: ?*ecs_stack_cursor_t = null,
};

/// Initialize a stack allocator.
pub extern fn flecs_stack_init(stack: *ecs_stack_t) void;

/// Deinitialize a stack allocator.
pub extern fn flecs_stack_fini(stack: *ecs_stack_t) void;

/// Allocate memory from the stack.
pub extern fn flecs_stack_alloc(stack: *ecs_stack_t, size: ecs_size_t, @"align": ecs_size_t) ?*anyopaque;

/// Allocate zeroed memory from the stack.
pub extern fn flecs_stack_calloc(stack: *ecs_stack_t, size: ecs_size_t, @"align": ecs_size_t) ?*anyopaque;

/// Free memory allocated from the stack.
pub extern fn flecs_stack_free(ptr: ?*anyopaque, size: ecs_size_t) void;

/// Reset the stack allocator.
pub extern fn flecs_stack_reset(stack: *ecs_stack_t) void;

/// Get a cursor marking the current position in the stack.
pub extern fn flecs_stack_get_cursor(stack: *ecs_stack_t) ?*ecs_stack_cursor_t;

/// Restore the stack to a previously saved cursor position.
pub extern fn flecs_stack_restore_cursor(stack: *ecs_stack_t, cursor: *ecs_stack_cursor_t) void;

pub const ecs_map_data_t = u64;

pub const ecs_map_key_t = ecs_map_data_t;

pub const ecs_map_val_t = ecs_map_data_t;

pub const ecs_bucket_entry_t = extern struct {
    key: ecs_map_key_t = 0,
    value: ecs_map_val_t = 0,
    next: ?*ecs_bucket_entry_t = null,
};

pub const ecs_bucket_t = extern struct {
    first: ?*ecs_bucket_entry_t = null,
};

/// flecs gives this struct extra fields under `FLECS_DEBUG`, so it is a different size in a
/// checked build than in a shipping one. Both are spelled out rather than assembled
/// at comptime: this file exists to read like the C it mirrors.
pub const ecs_map_iter_t = if (flecs_debug) extern struct {
    map: ?*const ecs_map_t = null,
    bucket: ?*ecs_bucket_t = null,
    entry: ?*ecs_bucket_entry_t = null,
    /// The current pair: `res[0]` is the key, `res[1]` the value.
    res: ?[*]ecs_map_data_t = null,
    change_count: i32 = 0,
} else extern struct {
    map: ?*const ecs_map_t = null,
    bucket: ?*ecs_bucket_t = null,
    entry: ?*ecs_bucket_entry_t = null,
    /// The current pair: `res[0]` is the key, `res[1]` the value.
    res: ?[*]ecs_map_data_t = null,
};

/// Initialize a new map.
pub extern fn ecs_map_init(map: *ecs_map_t, allocator: ?*ecs_allocator_t) void;

/// Initialize a new map if uninitialized, leave as is otherwise.
pub extern fn ecs_map_init_if(map: *ecs_map_t, allocator: ?*ecs_allocator_t) void;

/// Reclaim map memory.
pub extern fn ecs_map_reclaim(map: *ecs_map_t) void;

/// Deinitialize a map.
pub extern fn ecs_map_fini(map: *ecs_map_t) void;

/// Get an element for a key. Returns NULL if the key doesn't exist.
pub extern fn ecs_map_get(map: *const ecs_map_t, key: ecs_map_key_t) ?*ecs_map_val_t;

/// Get element as pointer (auto-dereferences _ptr).
pub extern fn ecs_map_get_deref_(map: *const ecs_map_t, key: ecs_map_key_t) ?*anyopaque;

/// Get or insert an element for a key.
pub extern fn ecs_map_ensure(map: *ecs_map_t, key: ecs_map_key_t) ?*ecs_map_val_t;

/// Get or insert a pointer element for a key. Allocate if the pointer is NULL.
pub extern fn ecs_map_ensure_alloc(map: *ecs_map_t, elem_size: ecs_size_t, key: ecs_map_key_t) ?*anyopaque;

/// Insert an element for a key.
pub extern fn ecs_map_insert(map: *ecs_map_t, key: ecs_map_key_t, value: ecs_map_val_t) void;

/// Insert a pointer element for a key, populate with a new allocation.
pub extern fn ecs_map_insert_alloc(map: *ecs_map_t, elem_size: ecs_size_t, key: ecs_map_key_t) ?*anyopaque;

/// Remove a key from the map.
pub extern fn ecs_map_remove(map: *ecs_map_t, key: ecs_map_key_t) ecs_map_val_t;

/// Remove a pointer element. Free if not NULL.
pub extern fn ecs_map_remove_free(map: *ecs_map_t, key: ecs_map_key_t) void;

/// Remove all elements from the map.
pub extern fn ecs_map_clear(map: *ecs_map_t) void;

/// Return an iterator to map contents.
pub extern fn ecs_map_iter(map: *const ecs_map_t) ecs_map_iter_t;

/// Return whether the map iterator is valid.
pub extern fn ecs_map_iter_valid(iter: *ecs_map_iter_t) bool;

/// Obtain the next element in the map from the iterator.
pub extern fn ecs_map_next(iter: *ecs_map_iter_t) bool;

/// Copy a map. `dst` must be empty or uninitialized.
pub extern fn ecs_map_copy(dst: *ecs_map_t, src: *const ecs_map_t) void;

pub extern var ecs_block_allocator_alloc_count: i64;

pub extern var ecs_block_allocator_free_count: i64;

pub extern var ecs_stack_allocator_alloc_count: i64;

pub extern var ecs_stack_allocator_free_count: i64;

/// Initialize an allocator.
pub extern fn flecs_allocator_init(a: *ecs_allocator_t) void;

/// Deinitialize an allocator.
pub extern fn flecs_allocator_fini(a: *ecs_allocator_t) void;

/// Get or create a block allocator for the specified size.
pub extern fn flecs_allocator_get(a: *ecs_allocator_t, size: ecs_size_t) ?*ecs_block_allocator_t;

/// Duplicate a string using the allocator. Free the result with `flecs_strfree` and the
/// same allocator, not with `ecs_os_free`.
pub extern fn flecs_strdup(a: *ecs_allocator_t, str: [*:0]const u8) ?[*:0]u8;

/// Free a string previously allocated with flecs_strdup().
pub extern fn flecs_strfree(a: *ecs_allocator_t, str: [*:0]u8) void;

/// Duplicate a memory block using the allocator.
pub extern fn flecs_dup(a: *ecs_allocator_t, size: ecs_size_t, src: ?*const anyopaque) ?*anyopaque;

pub const ecs_strbuf_list_elem = extern struct {
    count: i32 = 0,
    separator: ?[*:0]const u8 = null,
};

pub const ecs_strbuf_t = extern struct {
    content: ?[*:0]u8 = null,
    length: ecs_size_t = 0,
    size: ecs_size_t = 0,
    list_stack: [32]ecs_strbuf_list_elem = @splat(.{}),
    list_sp: i32 = 0,
    small_string: [512]u8 = @splat(0),
};

/// Append a format string to a buffer.
pub extern fn ecs_strbuf_append(buffer: *ecs_strbuf_t, fmt: [*:0]const u8, ...) void;

/// Append a format string with an argument list to a buffer.
pub extern fn ecs_strbuf_vappend(buffer: *ecs_strbuf_t, fmt: [*:0]const u8, args: va_list) void;

/// Append a string to a buffer.
pub extern fn ecs_strbuf_appendstr(buffer: *ecs_strbuf_t, str: [*:0]const u8) void;

/// Append a character to a buffer.
pub extern fn ecs_strbuf_appendch(buffer: *ecs_strbuf_t, ch: u8) void;

/// Append an int to a buffer.
pub extern fn ecs_strbuf_appendint(buffer: *ecs_strbuf_t, v: i64) void;

/// Append a float to a buffer.
pub extern fn ecs_strbuf_appendflt(buffer: *ecs_strbuf_t, v: f64, nan_delim: u8) void;

/// Append a boolean to a buffer.
pub extern fn ecs_strbuf_appendbool(buffer: *ecs_strbuf_t, v: bool) void;

/// Append a source buffer to a destination buffer, and reset the source.
pub extern fn ecs_strbuf_mergebuff(dst_buffer: *ecs_strbuf_t, src_buffer: *ecs_strbuf_t) void;

/// Append `n` bytes. `str` need not be terminated, and is not read past `n`.
pub extern fn ecs_strbuf_appendstrn(buffer: *ecs_strbuf_t, str: [*]const u8, n: i32) void;

/// Take the result and reset the buffer. Always heap, even for a short string that lived
/// in the buffer's inline storage; free it with `ecs_os_free`. Null if nothing was
/// appended.
pub extern fn ecs_strbuf_get(buffer: *ecs_strbuf_t) ?[*:0]u8;

/// Same as `ecs_strbuf_get`, but without the copy: if the content still fits the inline
/// storage the result points into `buffer` and must not be freed or outlive it, and if it
/// does not, the result is heap and leaks unless freed. Only safe where the length is
/// known to be small.
pub extern fn ecs_strbuf_get_small(buffer: *ecs_strbuf_t) ?[*:0]u8;

/// Reset a buffer without returning a string.
pub extern fn ecs_strbuf_reset(buffer: *ecs_strbuf_t) void;

/// Open a list. `separator` is written before every element but the first, and lists
/// nest up to 32 deep.
pub extern fn ecs_strbuf_list_push(buffer: *ecs_strbuf_t, list_open: [*:0]const u8, separator: [*:0]const u8) void;

/// Pop a list.
pub extern fn ecs_strbuf_list_pop(buffer: *ecs_strbuf_t, list_close: [*:0]const u8) void;

/// Insert a new element in the list.
pub extern fn ecs_strbuf_list_next(buffer: *ecs_strbuf_t) void;

/// Append a character as a new element in the list.
pub extern fn ecs_strbuf_list_appendch(buffer: *ecs_strbuf_t, ch: u8) void;

/// Append a formatted string as a new element in the list.
pub extern fn ecs_strbuf_list_append(buffer: *ecs_strbuf_t, fmt: [*:0]const u8, ...) void;

/// Append a string as a new element in the list.
pub extern fn ecs_strbuf_list_appendstr(buffer: *ecs_strbuf_t, str: [*:0]const u8) void;

/// Append `n` bytes as a new element in the list.
pub extern fn ecs_strbuf_list_appendstrn(buffer: *ecs_strbuf_t, str: [*]const u8, n: i32) void;

/// Return the number of bytes written to the buffer.
pub extern fn ecs_strbuf_written(buffer: *const ecs_strbuf_t) i32;

pub const ecs_time_t = extern struct {
    sec: u32 = 0,
    nanosec: u32 = 0,
};

pub const ecs_os_thread_t = usize;

pub const ecs_os_cond_t = usize;

pub const ecs_os_mutex_t = usize;

pub const ecs_os_dl_t = usize;

pub const ecs_os_thread_id_t = u64;

pub const ecs_os_proc_t = ?*const fn () callconv(.c) void;

pub const ecs_os_thread_callback_t = ?*const fn (param: ?*anyopaque) callconv(.c) ?*anyopaque;

pub const ecs_os_api_init_t = ?*const fn () callconv(.c) void;

pub const ecs_os_api_fini_t = ?*const fn () callconv(.c) void;

pub const ecs_os_api_malloc_t = ?*const fn (size: ecs_size_t) callconv(.c) ?*anyopaque;

pub const ecs_os_api_free_t = ?*const fn (ptr: ?*anyopaque) callconv(.c) void;

pub const ecs_os_api_realloc_t = ?*const fn (ptr: ?*anyopaque, size: ecs_size_t) callconv(.c) ?*anyopaque;

pub const ecs_os_api_calloc_t = ?*const fn (size: ecs_size_t) callconv(.c) ?*anyopaque;

pub const ecs_os_api_strdup_t = ?*const fn (str: ?[*:0]const u8) callconv(.c) ?[*:0]u8;

pub const ecs_os_api_thread_new_t = ?*const fn (callback: ecs_os_thread_callback_t, param: ?*anyopaque) callconv(.c) ecs_os_thread_t;

pub const ecs_os_api_thread_join_t = ?*const fn (thread: ecs_os_thread_t) callconv(.c) ?*anyopaque;

pub const ecs_os_api_thread_self_t = ?*const fn () callconv(.c) ecs_os_thread_id_t;

pub const ecs_os_api_ainc_t = ?*const fn (value: *i32) callconv(.c) i32;

pub const ecs_os_api_lainc_t = ?*const fn (value: *i64) callconv(.c) i64;

pub const ecs_os_api_mutex_new_t = ?*const fn () callconv(.c) ecs_os_mutex_t;

pub const ecs_os_api_mutex_free_t = ?*const fn (mutex: ecs_os_mutex_t) callconv(.c) void;

pub const ecs_os_api_mutex_lock_t = ?*const fn (mutex: ecs_os_mutex_t) callconv(.c) void;

pub const ecs_os_api_cond_new_t = ?*const fn () callconv(.c) ecs_os_cond_t;

pub const ecs_os_api_cond_free_t = ?*const fn (cond: ecs_os_cond_t) callconv(.c) void;

pub const ecs_os_api_cond_signal_t = ?*const fn (cond: ecs_os_cond_t) callconv(.c) void;

pub const ecs_os_api_cond_broadcast_t = ?*const fn (cond: ecs_os_cond_t) callconv(.c) void;

pub const ecs_os_api_cond_wait_t = ?*const fn (cond: ecs_os_cond_t, mutex: ecs_os_mutex_t) callconv(.c) void;

pub const ecs_os_api_sleep_t = ?*const fn (sec: i32, nanosec: i32) callconv(.c) void;

pub const ecs_os_api_now_t = ?*const fn () callconv(.c) u64;

pub const ecs_os_api_get_time_t = ?*const fn (time_out: *ecs_time_t) callconv(.c) void;

pub const ecs_os_api_log_t = ?*const fn (level: i32, file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) callconv(.c) void;

pub const ecs_os_api_abort_t = ?*const fn () callconv(.c) void;

pub const ecs_os_api_dlopen_t = ?*const fn (libname: ?[*:0]const u8) callconv(.c) ecs_os_dl_t;

pub const ecs_os_api_dlproc_t = ?*const fn (lib: ecs_os_dl_t, procname: ?[*:0]const u8) callconv(.c) ecs_os_proc_t;

pub const ecs_os_api_dlclose_t = ?*const fn (lib: ecs_os_dl_t) callconv(.c) void;

pub const ecs_os_api_module_to_path_t = ?*const fn (module_id: ?[*:0]const u8) callconv(.c) ?[*:0]u8;

pub const ecs_os_api_fopen_t = ?*const fn (file: ?[*:0]const u8, mode: ?[*:0]const u8) callconv(.c) ?*anyopaque;

pub const ecs_os_api_fclose_t = ?*const fn (file: ?*anyopaque) callconv(.c) void;

pub const ecs_os_api_perf_trace_t = ?*const fn (filename: ?[*:0]const u8, line: usize, name: ?[*:0]const u8) callconv(.c) void;

pub const ecs_os_api_t = extern struct {
    init_: ecs_os_api_init_t = null,
    fini_: ecs_os_api_fini_t = null,
    malloc_: ecs_os_api_malloc_t = null,
    realloc_: ecs_os_api_realloc_t = null,
    calloc_: ecs_os_api_calloc_t = null,
    free_: ecs_os_api_free_t = null,
    strdup_: ecs_os_api_strdup_t = null,
    thread_new_: ecs_os_api_thread_new_t = null,
    thread_join_: ecs_os_api_thread_join_t = null,
    thread_self_: ecs_os_api_thread_self_t = null,
    task_new_: ecs_os_api_thread_new_t = null,
    task_join_: ecs_os_api_thread_join_t = null,
    ainc_: ecs_os_api_ainc_t = null,
    adec_: ecs_os_api_ainc_t = null,
    lainc_: ecs_os_api_lainc_t = null,
    ladec_: ecs_os_api_lainc_t = null,
    mutex_new_: ecs_os_api_mutex_new_t = null,
    mutex_free_: ecs_os_api_mutex_free_t = null,
    mutex_lock_: ecs_os_api_mutex_lock_t = null,
    mutex_unlock_: ecs_os_api_mutex_lock_t = null,
    cond_new_: ecs_os_api_cond_new_t = null,
    cond_free_: ecs_os_api_cond_free_t = null,
    cond_signal_: ecs_os_api_cond_signal_t = null,
    cond_broadcast_: ecs_os_api_cond_broadcast_t = null,
    cond_wait_: ecs_os_api_cond_wait_t = null,
    sleep_: ecs_os_api_sleep_t = null,
    now_: ecs_os_api_now_t = null,
    get_time_: ecs_os_api_get_time_t = null,
    log_: ecs_os_api_log_t = null,
    abort_: ecs_os_api_abort_t = null,
    dlopen_: ecs_os_api_dlopen_t = null,
    dlproc_: ecs_os_api_dlproc_t = null,
    dlclose_: ecs_os_api_dlclose_t = null,
    module_to_dl_: ecs_os_api_module_to_path_t = null,
    module_to_etc_: ecs_os_api_module_to_path_t = null,
    fopen_: ecs_os_api_fopen_t = null,
    fclose_: ecs_os_api_fclose_t = null,
    perf_trace_push_: ecs_os_api_perf_trace_t = null,
    perf_trace_pop_: ecs_os_api_perf_trace_t = null,
    log_level_: i32 = 0,
    log_indent_: i32 = 0,
    log_last_error_: i32 = 0,
    log_last_timestamp_: i64 = 0,
    flags_: ecs_flags32_t = 0,
    log_out_: ?*anyopaque = null,
};

/// The live callback table. Read a field to see what flecs will call; replace the lot
/// with `ecs_os_set_api`, which is the only way that takes effect after `ecs_os_init`.
pub extern var ecs_os_api: ecs_os_api_t;

/// flecs defines this as `ecs_flags<FLECS_TERM_COUNT_MAX>_t` — a bitset with exactly one
/// bit per term — so the maximum term count changes the width of four fields in
/// `ecs_iter_t` and therefore the size of the struct. Deriving it the same way here is
/// what keeps `-Dterm_count_max` from silently producing two different iterators.
pub const ecs_termset_t = switch (FLECS_TERM_COUNT_MAX) {
    8 => ecs_flags8_t,
    16 => ecs_flags16_t,
    32 => ecs_flags32_t,
    64 => ecs_flags64_t,
    else => @compileError(
        "term_count_max must be 8, 16, 32 or 64: flecs names the bitset type " ++
            "ecs_flags<N>_t after it, and no other width exists",
    ),
};

pub const ecs_iter_action_t = ?*const fn (it: *ecs_iter_t) callconv(.c) void;

pub const ecs_run_action_t = ?*const fn (it: *ecs_iter_t) callconv(.c) void;

pub const ecs_iter_next_action_t = ?*const fn (it: *ecs_iter_t) callconv(.c) bool;

pub const ecs_iter_fini_action_t = ?*const fn (it: *ecs_iter_t) callconv(.c) void;

pub const ecs_ctx_free_t = ?*const fn (ctx: ?*anyopaque) callconv(.c) void;

pub const ecs_order_by_action_t = ?*const fn (
    e1: ecs_entity_t,
    ptr1: ?*const anyopaque,
    e2: ecs_entity_t,
    ptr2: ?*const anyopaque,
) callconv(.c) c_int;

pub const ecs_sort_table_action_t = ?*const fn (
    world: ?*ecs_world_t,
    table: ?*ecs_table_t,
    entities: ?[*]ecs_entity_t,
    ptr: ?*anyopaque,
    size: i32,
    lo: i32,
    hi: i32,
    order_by: ecs_order_by_action_t,
) callconv(.c) void;

pub const ecs_group_by_action_t = ?*const fn (
    world: ?*ecs_world_t,
    table: ?*ecs_table_t,
    group_id: ecs_id_t,
    ctx: ?*anyopaque,
) callconv(.c) u64;

pub const ecs_group_create_action_t = ?*const fn (
    world: ?*ecs_world_t,
    group_id: u64,
    group_by_ctx: ?*anyopaque,
) callconv(.c) ?*anyopaque;

pub const ecs_group_delete_action_t = ?*const fn (
    world: ?*ecs_world_t,
    group_id: u64,
    group_ctx: ?*anyopaque,
    group_by_ctx: ?*anyopaque,
) callconv(.c) void;

pub const ecs_module_action_t = ?*const fn (world: *ecs_world_t) callconv(.c) void;

pub const ecs_fini_action_t = ?*const fn (world: *ecs_world_t, ctx: ?*anyopaque) callconv(.c) void;

pub const ecs_compare_action_t = ?*const fn (ptr1: ?*const anyopaque, ptr2: ?*const anyopaque) callconv(.c) c_int;

pub const ecs_hash_value_action_t = ?*const fn (ptr: ?*const anyopaque) callconv(.c) u64;

pub const ecs_xtor_t = ?*const fn (ptr: ?*anyopaque, count: i32, type_info: ?*const ecs_type_info_t) callconv(.c) void;

pub const ecs_copy_t = ?*const fn (dst: ?*anyopaque, src: ?*const anyopaque, count: i32, type_info: ?*const ecs_type_info_t) callconv(.c) void;

pub const ecs_move_t = ?*const fn (dst: ?*anyopaque, src: ?*anyopaque, count: i32, type_info: ?*const ecs_type_info_t) callconv(.c) void;

pub const ecs_cmp_t = ?*const fn (a: ?*const anyopaque, b: ?*const anyopaque, type_info: ?*const ecs_type_info_t) callconv(.c) c_int;

pub const ecs_equals_t = ?*const fn (a: ?*const anyopaque, b: ?*const anyopaque, type_info: ?*const ecs_type_info_t) callconv(.c) bool;

pub const flecs_poly_dtor_t = ?*const fn (poly: ?*ecs_poly_t) callconv(.c) void;

pub const ecs_inout_kind_t = c_uint;

pub const EcsInOutDefault: i16 = 0;

pub const EcsInOutNone: i16 = 1;

pub const EcsInOutFilter: i16 = 2;

pub const EcsInOut: i16 = 3;

pub const EcsIn: i16 = 4;

pub const EcsOut: i16 = 5;

pub const ecs_oper_kind_t = c_uint;

pub const EcsAnd: i16 = 0;

pub const EcsOr: i16 = 1;

pub const EcsNot: i16 = 2;

pub const EcsOptional: i16 = 3;

pub const EcsAndFrom: i16 = 4;

pub const EcsOrFrom: i16 = 5;

pub const EcsNotFrom: i16 = 6;

/// C spells this as an enum, so it compiles to an unsigned int and any value fits.
/// Mirroring it as a Zig enum would make a value flecs invents later illegal to even
/// represent; the raw layer stays an integer, and `zecs.CacheKind` is the real enum.
pub const ecs_query_cache_kind_t = c_uint;

pub const EcsQueryCacheDefault: ecs_query_cache_kind_t = 0;

pub const EcsQueryCacheAuto: ecs_query_cache_kind_t = 1;

pub const EcsQueryCacheAll: ecs_query_cache_kind_t = 2;

pub const EcsQueryCacheNone: ecs_query_cache_kind_t = 3;

/// Match the entity the term is evaluated on.
pub const EcsSelf: ecs_flags64_t = 1 << 63;

/// Follow `trav` upwards and match what it leads to.
pub const EcsUp: ecs_flags64_t = 1 << 62;

/// Match by traversing downwards, ordering parents before children.
pub const EcsTrav: ecs_flags64_t = 1 << 61;

/// Like `EcsUp`, but ordered breadth-first over the hierarchy.
pub const EcsCascade: ecs_flags64_t = 1 << 60;

/// With `EcsCascade`, reverse the ordering.
pub const EcsDesc: ecs_flags64_t = 1 << 59;

/// The term ref names a query variable rather than an entity.
pub const EcsIsVariable: ecs_flags64_t = 1 << 58;

/// The term ref is an entity, including entity 0.
pub const EcsIsEntity: ecs_flags64_t = 1 << 57;

/// The term ref names an entity by name.
pub const EcsIsName: ecs_flags64_t = 1 << 56;

pub const EcsTraverseFlags: ecs_flags64_t = EcsSelf | EcsUp | EcsTrav | EcsCascade | EcsDesc;

pub const ecs_term_ref_t = extern struct {
    id: ecs_entity_t = 0,
    name: ?[*:0]const u8 = null,
};

/// Table data.
pub const ecs_data_t = opaque {};

pub const ecs_query_cache_match_t = opaque {};

pub const ecs_query_cache_group_t = opaque {};

pub const ecs_event_record_t = opaque {};

pub const ecs_table_range_t = extern struct {
    table: ?*ecs_table_t = null,
    offset: i32 = 0,
    count: i32 = 0,
};

pub const ecs_var_t = extern struct {
    range: ecs_table_range_t = .{},
    entity: ecs_entity_t = 0,
};

pub const ecs_page_iter_t = extern struct {
    offset: i32 = 0,
    limit: i32 = 0,
    remaining: i32 = 0,
};

pub const ecs_worker_iter_t = extern struct {
    index: i32 = 0,
    count: i32 = 0,
};

pub const ecs_table_cache_iter_t = extern struct {
    cur: ?*const anyopaque = null,
    next: ?*const anyopaque = null,
    iter_fill: bool = false,
    iter_empty: bool = false,
};

pub const ecs_each_iter_t = extern struct {
    it: ecs_table_cache_iter_t = .{},
    ids: ecs_id_t = 0,
    sources: ecs_entity_t = 0,
    sizes: ecs_size_t = 0,
    columns: i16 = 0,
    trs: ?*const ecs_table_record_t = null,
};

pub const ecs_query_op_profile_t = extern struct {
    count: [2]i32 = @splat(0),
};

pub const ecs_query_iter_t = extern struct {
    vars: ?*anyopaque = null,
    query_vars: ?*const ecs_query_var_t = null,
    ops: ?*const ecs_query_op_t = null,
    op_ctx: ?*ecs_query_op_ctx_t = null,
    written: ?[*]u64 = null,
    group: ?*anyopaque = null,
    tables: ?*anyopaque = null,
    all_tables: ?*anyopaque = null,
    elem: ?*anyopaque = null,
    cur: i32 = 0,
    all_cur: i32 = 0,
    profile: ?*anyopaque = null,
    op: i16 = 0,
    iter_single_group: bool = false,
};

pub const ecs_iter_private_t = extern struct {
    iter: extern union {
        query: ecs_query_iter_t,
        page: ecs_page_iter_t,
        worker: ecs_worker_iter_t,
        each: ecs_each_iter_t,
    } = .{ .query = .{} },
    entity_iter: ?*anyopaque = null,
    stack_cursor: ?*anyopaque = null,
};

pub const ecs_commands_t = extern struct {
    queue: ecs_vec_t = .{},
    stack: ecs_stack_t = .{},
    entries: ecs_sparse_t = .{},
};

/// Convert a PascalCase module name into a path: `MyFooModule` becomes `my.foo.module`.
/// Free the result with `ecs_os_free`.
pub extern fn flecs_module_path_from_c(c_name: [*:0]const u8) ?[*:0]u8;

/// Constructor that zero-initializes a component value.
pub extern fn flecs_default_ctor(ptr: ?*anyopaque, count: i32, type_info: ?*const ecs_type_info_t) void;

pub extern fn flecs_type_info_ctor(ptr: ?*anyopaque, count: i32, type_info: ?*const ecs_type_info_t) bool;

pub extern fn flecs_type_info_dtor(ptr: ?*anyopaque, count: i32, type_info: ?*const ecs_type_info_t) bool;

pub extern fn flecs_type_info_copy(dst: ?*anyopaque, src: ?*const anyopaque, count: i32, type_info: ?*const ecs_type_info_t) void;

pub extern fn flecs_type_info_move(dst: ?*anyopaque, src: ?*anyopaque, count: i32, type_info: ?*const ecs_type_info_t) void;

pub extern fn flecs_type_info_copy_ctor(dst: ?*anyopaque, src: ?*const anyopaque, count: i32, type_info: ?*const ecs_type_info_t) void;

pub extern fn flecs_type_info_move_ctor(dst: ?*anyopaque, src: ?*anyopaque, count: i32, type_info: ?*const ecs_type_info_t) void;

pub extern fn flecs_type_info_ctor_move_dtor(dst: ?*anyopaque, src: ?*anyopaque, count: i32, type_info: ?*const ecs_type_info_t) void;

pub extern fn flecs_type_info_move_dtor(dst: ?*anyopaque, src: ?*anyopaque, count: i32, type_info: ?*const ecs_type_info_t) void;

pub extern fn flecs_type_info_cmp(a: ?*const anyopaque, b: ?*const anyopaque, type_info: ?*const ecs_type_info_t) c_int;

pub extern fn flecs_type_info_equals(a: ?*const anyopaque, b: ?*const anyopaque, type_info: ?*const ecs_type_info_t) bool;

/// Format into a fresh allocation. Free the result with `ecs_os_free`.
pub extern fn flecs_vasprintf(fmt: [*:0]const u8, args: va_list) ?[*:0]u8;

/// Format into a fresh allocation. Free the result with `ecs_os_free`.
pub extern fn flecs_asprintf(fmt: [*:0]const u8, ...) ?[*:0]u8;

/// Write `in` to `out`, escaping it if `delimiter` demands. Returns the position just
/// past the last byte written; nothing is terminated, so `out` is a plain buffer.
pub extern fn flecs_chresc(out: [*]u8, in: u8, delimiter: u8) [*]u8;

/// Read one character from `in`, resolving an escape sequence, and store it in `out`.
/// Returns the position just past what was read, or null if the escape was malformed.
pub extern fn flecs_chrparse(in: [*:0]const u8, out: *u8) ?[*:0]const u8;

/// Escape `in` into `out`, writing at most `size` bytes, and return the length the result
/// wants. Call it with a null `out` first to get that length, then again with a buffer.
pub extern fn flecs_stresc(out: ?[*]u8, size: ecs_size_t, delimiter: u8, in: [*:0]const u8) ecs_size_t;

/// Same as `flecs_stresc`, but allocates the right size itself. Free with `ecs_os_free`.
pub extern fn flecs_astresc(delimiter: u8, in: [*:0]const u8) ?[*:0]u8;

/// Skip whitespace and newlines, returning the first character that is neither.
pub extern fn flecs_parse_ws_eol(ptr: [*:0]const u8) [*:0]const u8;

/// Copy the leading run of digits at `ptr` into `token`, terminated, and return the first
/// character that is not a digit. There must be at least one.
pub extern fn flecs_parse_digit(ptr: [*:0]const u8, token: [*]u8, token_size: i32) ?[*:0]const u8;

/// Convert an identifier to snake case. Free the result with `ecs_os_free`.
pub extern fn flecs_to_snake_case(str: [*:0]const u8) ?[*:0]u8;

pub const ecs_suspend_readonly_state_t = extern struct {
    is_readonly: bool = false,
    is_deferred: bool = false,
    cmd_flushing: bool = false,
    defer_count: i32 = 0,
    scope: ecs_entity_t = 0,
    with: ecs_entity_t = 0,
    cmd_stack: [2]ecs_commands_t = @splat(.{}),
    cmd: ?*ecs_commands_t = null,
    stage: ?*ecs_stage_t = null,
};

/// Leave readonly mode for the duration of one operation. `state` is scratch space the
/// caller owns; hand the same one back to `flecs_resume_readonly`.
pub extern fn flecs_suspend_readonly(world: *const ecs_world_t, state: *ecs_suspend_readonly_state_t) ?*ecs_world_t;

pub extern fn flecs_resume_readonly(world: *ecs_world_t, state: *ecs_suspend_readonly_state_t) void;

/// How many entities in a table are traversable targets of a relationship. Exported for
/// flecs's own tests.
pub extern fn flecs_table_observed_count(table: *const ecs_table_t) i32;

/// Print a backtrace. `stream` is a C `FILE*`.
pub extern fn flecs_dump_backtrace(stream: *anyopaque) void;

/// Increase the refcount of a poly object.
pub extern fn flecs_poly_claim_(poly: *ecs_poly_t) i32;

/// Decrease the refcount of a poly object.
pub extern fn flecs_poly_release_(poly: *ecs_poly_t) i32;

/// Return the refcount of a poly object.
pub extern fn flecs_poly_refcount(poly: *ecs_poly_t) i32;

/// Claim a slot in the per-world component id table. A language binding takes one slot
/// per component type it wants to register, and then maps it to a per-world id with
/// `flecs_component_ids_get` and `flecs_component_ids_set`. Slots are never released.
pub extern fn flecs_component_ids_index_get() i32;

/// Get a world-local component ID.
pub extern fn flecs_component_ids_get(world: *const ecs_world_t, index: i32) ecs_entity_t;

/// Get an alive world-local component ID. Same as flecs_component_ids_get(), but
/// returns 0 if the component is no longer alive.
pub extern fn flecs_component_ids_get_alive(world: *const ecs_world_t, index: i32) ecs_entity_t;

/// Set a world-local component ID.
pub extern fn flecs_component_ids_set(world: *ecs_world_t, index: i32, id: ecs_entity_t) void;

/// The fast path for iterating a cached query with no work per term. Only valid for an
/// iterator flecs has already judged trivial.
pub extern fn flecs_query_trivial_cached_next(it: *ecs_iter_t) bool;

/// Panic unless the calling thread holds exclusive write access to the world. flecs calls
/// this itself before mutating; it becomes an empty macro without the exclusive access
/// addon, so the ABI guard treats it as one.
pub extern fn flecs_check_exclusive_world_access_write(world: *const ecs_world_t) void;

/// Same as flecs_check_exclusive_world_access_write(), but for read access.
pub extern fn flecs_check_exclusive_world_access_read(world: *const ecs_world_t) void;

/// End deferred mode (executes commands when stage->defer becomes 0).
pub extern fn flecs_defer_end(world: *ecs_world_t, stage: *ecs_stage_t) bool;

/// The journalling addon's operation counter, one tick per operation. Useful for
/// re-running up to the operation that went wrong. Not thread-safe.
pub extern fn flecs_journal_get_counter() c_int;

pub const ecs_hm_bucket_t = extern struct {
    keys: ecs_vec_t = .{},
    values: ecs_vec_t = .{},
};

pub const ecs_hashmap_t = opaque {};

pub const flecs_hashmap_iter_t = extern struct {
    it: ecs_map_iter_t = .{},
    bucket: ?*ecs_hm_bucket_t = null,
    index: i32 = 0,
};

pub const flecs_hashmap_result_t = extern struct {
    key: ?*anyopaque = null,
    value: ?*anyopaque = null,
    hash: u64 = 0,
};

/// Initialize a hashmap.
pub extern fn flecs_hashmap_init_(hm: *ecs_hashmap_t, key_size: ecs_size_t, value_size: ecs_size_t, hash: ecs_hash_value_action_t, compare: ecs_compare_action_t, allocator: ?*ecs_allocator_t) void;

/// Deinitialize a hashmap.
pub extern fn flecs_hashmap_fini(map: *ecs_hashmap_t) void;

/// Get a value from the hashmap.
pub extern fn flecs_hashmap_get_(map: *const ecs_hashmap_t, key_size: ecs_size_t, key: ?*const anyopaque, value_size: ecs_size_t) ?*anyopaque;

/// Ensure a key exists in the hashmap, inserting if necessary.
pub extern fn flecs_hashmap_ensure_(map: *ecs_hashmap_t, key_size: ecs_size_t, key: ?*const anyopaque, value_size: ecs_size_t) flecs_hashmap_result_t;

/// Set a key-value pair in the hashmap.
pub extern fn flecs_hashmap_set_(map: *ecs_hashmap_t, key_size: ecs_size_t, key: ?*anyopaque, value_size: ecs_size_t, value: ?*const anyopaque) void;

/// Remove a key from the hashmap.
pub extern fn flecs_hashmap_remove_(map: *ecs_hashmap_t, key_size: ecs_size_t, key: ?*const anyopaque, value_size: ecs_size_t) void;

/// Remove a key from the hashmap using a precomputed hash.
pub extern fn flecs_hashmap_remove_w_hash_(map: *ecs_hashmap_t, key_size: ecs_size_t, key: ?*const anyopaque, value_size: ecs_size_t, hash: u64) void;

/// Get a bucket from the hashmap by hash value.
pub extern fn flecs_hashmap_get_bucket(map: *const ecs_hashmap_t, hash: u64) ?*ecs_hm_bucket_t;

/// Remove an entry from a hashmap bucket by index.
pub extern fn flecs_hm_bucket_remove(map: *ecs_hashmap_t, bucket: *ecs_hm_bucket_t, hash: u64, index: i32) void;

/// Copy a hashmap. `dst` and `src` must be different maps.
pub extern fn flecs_hashmap_copy(dst: *ecs_hashmap_t, src: *const ecs_hashmap_t) void;

/// Create an iterator for a hashmap.
pub extern fn flecs_hashmap_iter(map: *ecs_hashmap_t) flecs_hashmap_iter_t;

/// Get the next element from a hashmap iterator.
pub extern fn flecs_hashmap_next_(it: *flecs_hashmap_iter_t, key_size: ecs_size_t, key_out: ?*anyopaque, value_size: ecs_size_t) ?*anyopaque;

/// Common header of the per-table caches flecs keeps for each component.
pub const ecs_table_cache_hdr_t = extern struct {
    cr: ?*ecs_component_record_t = null,
    table: ?*ecs_table_t = null,
    prev: ?*ecs_table_cache_hdr_t = null,
    next: ?*ecs_table_cache_hdr_t = null,
};

pub const ecs_table_diff_t = extern struct {
    added: ecs_type_t = .{},
    removed: ecs_type_t = .{},
    added_flags: ecs_flags32_t = 0,
    removed_flags: ecs_flags32_t = 0,
};

pub const ecs_parent_record_t = extern struct {
    entity: u32 = 0,
    count: i32 = 0,
};

/// The record for an entity: where it lives, as a table and a row. Null if the entity is
/// not alive.
pub extern fn ecs_record_find(world: *const ecs_world_t, entity: ecs_entity_t) ?*ecs_record_t;

/// The entity a record belongs to. Only works for a record whose entity has a table,
/// which an entity with no components does not.
pub extern fn ecs_record_get_entity(record: *const ecs_record_t) ecs_entity_t;

/// Take exclusive write access to an entity's components without paying for deferring.
/// The lock is per table, not per entity, so one entity at a time per table; keeping
/// access exclusive is the caller's problem, and flecs only notices a second writer when
/// asserts are on. Needs the threading OS API. Always paired with `ecs_write_end`.
pub extern fn ecs_write_begin(world: *ecs_world_t, entity: ecs_entity_t) ?*ecs_record_t;

/// Release the access taken by `ecs_write_begin`.
pub extern fn ecs_write_end(record: *ecs_record_t) void;

/// Take read access to an entity's components. Readers do not exclude each other, only
/// writers. Needs the threading OS API. Always paired with `ecs_read_end`.
pub extern fn ecs_read_begin(world: *ecs_world_t, entity: ecs_entity_t) ?*const ecs_record_t;

/// Release the access taken by `ecs_read_begin`.
pub extern fn ecs_read_end(record: *const ecs_record_t) void;

/// Get a component from an entity record. This operation returns a pointer to a
/// component for the entity associated with the provided record. For safe access to the
/// component, obtain the record with ecs_read_begin() or ecs_write_begin().
pub extern fn ecs_record_get_id(world: *const ecs_world_t, record: *const ecs_record_t, id: ecs_id_t) ?*const anyopaque;

/// Same as ecs_record_get_id(), but returns a mutable pointer. For safe access to the
/// component, obtain the record with ecs_write_begin().
pub extern fn ecs_record_ensure_id(world: *ecs_world_t, record: *ecs_record_t, id: ecs_id_t) ?*anyopaque;

/// Test if the entity for a record has a (component) ID.
pub extern fn ecs_record_has_id(world: *ecs_world_t, record: *const ecs_record_t, id: ecs_id_t) bool;

/// Get a component pointer from a column and record. This returns a pointer to the
/// component using a table column index. The table's column index can be found with
/// ecs_table_get_column_index().
pub extern fn ecs_record_get_by_column(record: *const ecs_record_t, column: i32, size: usize) ?*anyopaque;

/// Get the component record for a component ID.
pub extern fn flecs_components_get(world: *const ecs_world_t, id: ecs_id_t) ?*ecs_component_record_t;

/// Ensure a component record for a component ID.
pub extern fn flecs_components_ensure(world: *ecs_world_t, id: ecs_id_t) ?*ecs_component_record_t;

/// Get the component ID from a component record.
pub extern fn flecs_component_get_id(cr: *const ecs_component_record_t) ecs_id_t;

/// Get the component flags for a component.
pub extern fn flecs_component_get_flags(world: *const ecs_world_t, id: ecs_id_t) ecs_flags32_t;

/// Get the type info for a component record.
pub extern fn flecs_component_get_type_info(cr: *const ecs_component_record_t) ?*const ecs_type_info_t;

/// Find the table record for a component record. This operation returns the table
/// record for the table and component record if it exists. If the record exists, it
/// means the table has the component.
pub extern fn flecs_component_get_table(cr: *const ecs_component_record_t, table: *const ecs_table_t) ?*const ecs_table_record_t;

/// Get the parent record for a component and table. A parent record stores how many
/// children for a parent are stored in the specified table. If the table only stores a
/// single child, the parent record will also store the entity ID of that child.
pub extern fn flecs_component_get_parent_record(cr: *const ecs_component_record_t, table: *const ecs_table_t) ?*ecs_parent_record_t;

/// Return the hierarchy depth for a component record. The specified component record
/// must be a ChildOf pair. This function does not compute the depth, it just returns
/// the precomputed depth that is updated automatically when hierarchy changes happen.
pub extern fn flecs_component_get_childof_depth(cr: *const ecs_component_record_t) i32;

/// Create a component record iterator. A component record iterator iterates all tables
/// for the specified component record.
pub extern fn flecs_component_iter(cr: *const ecs_component_record_t, iter_out: *ecs_table_cache_iter_t) bool;

/// Get the next table record for the iterator. Returns the next table record, or NULL
/// if there are no more results.
pub extern fn flecs_component_next(iter: *ecs_table_cache_iter_t) ?*const ecs_table_record_t;

/// Every record a table holds, as `array[0..count]`. Points into flecs's own storage.
pub const ecs_table_records_t = extern struct {
    array: ?[*]const ecs_table_record_t = null,
    count: i32 = 0,
};

/// Get the table records. This operation returns an array with all records for the
/// specified table.
pub extern fn flecs_table_records(table: *ecs_table_t) ecs_table_records_t;

/// Get the component record from a table record.
pub extern fn flecs_table_record_get_component(tr: *const ecs_table_record_t) ?*ecs_component_record_t;

/// Get the table ID. This operation returns a unique numerical identifier for a table.
pub extern fn flecs_table_id(table: *ecs_table_t) u64;

/// Find a table by adding an ID to the current table. Same as ecs_table_add_id(), but
/// with an additional diff parameter that contains information about the traversed
/// edge.
pub extern fn flecs_table_traverse_add(world: *ecs_world_t, table: *ecs_table_t, id_ptr: *ecs_id_t, diff: *ecs_table_diff_t) ?*ecs_table_t;

pub const ecs_value_t = extern struct {
    type: ecs_entity_t = 0,
    ptr: ?*anyopaque = null,
};

pub const ecs_entity_desc_t = extern struct {
    _canary: i32 = 0,
    id: ecs_entity_t = 0,
    parent: ecs_entity_t = 0,
    name: ?[*:0]const u8 = null,
    sep: ?[*:0]const u8 = null,
    root_sep: ?[*:0]const u8 = null,
    symbol: ?[*:0]const u8 = null,
    use_low_id: bool = false,
    /// Ids to add, terminated by a 0 id.
    add: ?[*:0]const ecs_id_t = null,
    /// Values to set, terminated by an element whose `type` is 0.
    set: ?[*]const ecs_value_t = null,
    add_expr: ?[*:0]const u8 = null,
};

pub const ecs_bulk_desc_t = extern struct {
    _canary: i32 = 0,
    /// `count` entities to populate, which must have no components yet. Null to have
    /// flecs create them instead.
    entities: ?[*]ecs_entity_t = null,
    count: i32 = 0,
    /// Sized by `FLECS_ID_DESC_MAX`, so `-Did_desc_max` changes this struct's size.
    ids: [FLECS_ID_DESC_MAX]ecs_id_t = @splat(0),
    /// One entry per id in `ids`, each pointing at `count` values. Null for a tag, and
    /// null for a component whose value the operation should leave alone.
    data: ?[*]?*anyopaque = null,
    table: ?*ecs_table_t = null,
};

pub const ecs_component_desc_t = extern struct {
    _canary: i32 = 0,
    entity: ecs_entity_t = 0,
    type: ecs_type_info_t = .{},
};

pub const EcsQueryMatchPrefab: ecs_flags32_t = 1 << 1;

pub const EcsQueryMatchDisabled: ecs_flags32_t = 1 << 2;

pub const EcsQueryMatchEmptyTables: ecs_flags32_t = 1 << 3;

pub const EcsQueryAllowUnresolvedByName: ecs_flags32_t = 1 << 6;

pub const EcsQueryTableOnly: ecs_flags32_t = 1 << 7;

pub const EcsQueryDetectChanges: ecs_flags32_t = 1 << 8;

pub const ecs_query_desc_t = extern struct {
    _canary: i32 = 0,
    terms: [FLECS_TERM_COUNT_MAX]ecs_term_t = @splat(.{}),
    expr: ?[*:0]const u8 = null,
    cache_kind: ecs_query_cache_kind_t = 0,
    flags: ecs_flags32_t = 0,
    order_by_callback: ecs_order_by_action_t = null,
    order_by_table_callback: ecs_sort_table_action_t = null,
    order_by: ecs_entity_t = 0,
    group_by: ecs_id_t = 0,
    group_by_callback: ecs_group_by_action_t = null,
    on_group_create: ecs_group_create_action_t = null,
    on_group_delete: ecs_group_delete_action_t = null,
    group_by_ctx: ?*anyopaque = null,
    group_by_ctx_free: ecs_ctx_free_t = null,
    ctx: ?*anyopaque = null,
    binding_ctx: ?*anyopaque = null,
    ctx_free: ecs_ctx_free_t = null,
    binding_ctx_free: ecs_ctx_free_t = null,
    entity: ecs_entity_t = 0,
};

pub const ecs_observer_desc_t = extern struct {
    _canary: i32 = 0,
    entity: ecs_entity_t = 0,
    query: ecs_query_desc_t = .{},
    events: [FLECS_EVENT_DESC_MAX]ecs_entity_t = @splat(0),
    yield_existing: bool = false,
    global_observer: bool = false,
    callback: ecs_iter_action_t = null,
    run: ecs_run_action_t = null,
    ctx: ?*anyopaque = null,
    ctx_free: ecs_ctx_free_t = null,
    callback_ctx: ?*anyopaque = null,
    callback_ctx_free: ecs_ctx_free_t = null,
    run_ctx: ?*anyopaque = null,
    run_ctx_free: ecs_ctx_free_t = null,
    last_event_id: ?*i32 = null,
    term_index_: i8 = 0,
    flags_: ecs_flags32_t = 0,
};

pub const ecs_event_desc_t = extern struct {
    event: ecs_entity_t = 0,
    ids: ?*const ecs_type_t = null,
    table: ?*ecs_table_t = null,
    other_table: ?*ecs_table_t = null,
    offset: i32 = 0,
    count: i32 = 0,
    entity: ecs_entity_t = 0,
    param: ?*anyopaque = null,
    const_param: ?*const anyopaque = null,
    observable: ?*ecs_poly_t = null,
    flags: ecs_flags32_t = 0,
};

pub const ecs_build_info_t = extern struct {
    compiler: ?[*:0]const u8 = null,
    /// The addons compiled in, as a null-terminated array of names.
    addons: ?[*:null]const ?[*:0]const u8 = null,
    /// The compile-time settings, as a null-terminated array of `NAME` or `NAME=value`.
    flags: ?[*:null]const ?[*:0]const u8 = null,
    version: ?[*:0]const u8 = null,
    version_major: i16 = 0,
    version_minor: i16 = 0,
    version_patch: i16 = 0,
    debug: bool = false,
    sanitize: bool = false,
    perf_trace: bool = false,
};

pub const ecs_world_info_t = extern struct {
    last_component_id: ecs_entity_t = 0,
    delta_time_raw: ecs_ftime_t = 0,
    delta_time: ecs_ftime_t = 0,
    time_scale: ecs_ftime_t = 0,
    target_fps: ecs_ftime_t = 0,
    frame_time_total: ecs_ftime_t = 0,
    system_time_total: ecs_ftime_t = 0,
    emit_time_total: ecs_ftime_t = 0,
    merge_time_total: ecs_ftime_t = 0,
    rematch_time_total: ecs_ftime_t = 0,
    world_time_total: f64 = 0,
    world_time_total_raw: f64 = 0,
    frame_count_total: i64 = 0,
    merge_count_total: i64 = 0,
    eval_comp_monitors_total: i64 = 0,
    rematch_count_total: i64 = 0,
    id_create_total: i64 = 0,
    id_delete_total: i64 = 0,
    table_create_total: i64 = 0,
    table_delete_total: i64 = 0,
    pipeline_build_count_total: i64 = 0,
    systems_ran_total: i64 = 0,
    observers_ran_total: i64 = 0,
    queries_ran_total: i64 = 0,
    tag_id_count: i32 = 0,
    component_id_count: i32 = 0,
    pair_id_count: i32 = 0,
    table_count: i32 = 0,
    creation_time: u32 = 0,
    cmd: extern struct {
        add_count: i64 = 0,
        remove_count: i64 = 0,
        delete_count: i64 = 0,
        clear_count: i64 = 0,
        set_count: i64 = 0,
        ensure_count: i64 = 0,
        modified_count: i64 = 0,
        discard_count: i64 = 0,
        event_count: i64 = 0,
        other_count: i64 = 0,
        batched_entity_count: i64 = 0,
        batched_command_count: i64 = 0,
    } = .{},
    name_prefix: ?[*:0]const u8 = null,
};

pub const ecs_query_group_info_t = extern struct {
    id: u64 = 0,
    match_count: i32 = 0,
    table_count: i32 = 0,
    ctx: ?*anyopaque = null,
};

pub const ecs_entity_range_t = extern struct {
    min: u32 = 0,
    max: u32 = 0,
    cur: u32 = 0,
    recycled: ecs_vec_t = .{},
};

/// A name or a symbol, held as `(EcsIdentifier, EcsName)` or `(EcsIdentifier, EcsSymbol)`.
/// `value` and the index behind it belong to flecs; write them through `ecs_set_name`
/// and friends rather than in place.
pub const EcsIdentifier = extern struct {
    value: ?[*:0]u8 = null,
    length: ecs_size_t = 0,
    hash: u64 = 0,
    index_hash: u64 = 0,
    index: ?*ecs_hashmap_t = null,
};

/// The size and alignment of a component. An entity is a component exactly when it has
/// this, and `size` 0 is what makes an id a tag.
pub const EcsComponent = extern struct {
    size: ecs_size_t = 0,
    alignment: ecs_size_t = 0,
};

/// The flecs object — query, observer, system — behind an entity that has one.
pub const EcsPoly = extern struct {
    poly: ?*ecs_poly_t = null,
};

/// Which component a serialization format should assume when a value is assigned to a
/// child without naming one. A hint only: no core operation reads it.
pub const EcsDefaultChildComponent = extern struct {
    component: ecs_id_t = 0,
};

/// The parent, for the non-fragmenting form of `ChildOf`.
pub const EcsParent = extern struct {
    value: ecs_entity_t = 0,
};

/// The cached children for one hierarchy depth. The vector holds flecs's own private
/// element type, so there is nothing here to read.
pub const ecs_tree_spawner_t = extern struct {
    children: ecs_vec_t = .{},
};

/// Tables cached per hierarchy depth, which is what makes instantiating a prefab tree
/// cheap when the root is not itself at depth zero.
pub const EcsTreeSpawner = extern struct {
    data: [6]ecs_tree_spawner_t = @splat(.{}),
};

pub extern const ECS_PAIR: ecs_id_t;

pub extern const ECS_VALUE_PAIR: ecs_id_t;

pub extern const ECS_AUTO_OVERRIDE: ecs_id_t;

pub extern const ECS_TOGGLE: ecs_id_t;

/// Relationship storing the entity's depth in a non-fragmenting hierarchy.
pub extern const EcsParentDepth: ecs_entity_t;

pub extern const EcsQuery: ecs_entity_t;

pub extern const EcsObserver: ecs_entity_t;

pub extern const EcsSystem: ecs_entity_t;

pub extern const EcsFlecs: ecs_entity_t;

pub extern const EcsWorld: ecs_entity_t;

pub extern const EcsWildcard: ecs_entity_t;

pub extern const EcsAny: ecs_entity_t;

pub extern const EcsThis: ecs_entity_t;

pub extern const EcsVariable: ecs_entity_t;

/// Core module scope.
pub extern const EcsFlecsCore: ecs_entity_t;

pub extern const EcsTransitive: ecs_entity_t;

pub extern const EcsFinal: ecs_entity_t;

pub extern const EcsExclusive: ecs_entity_t;

pub extern const EcsTraversable: ecs_entity_t;

pub extern const EcsSparse: ecs_entity_t;

pub extern const EcsOnInstantiate: ecs_entity_t;

pub extern const EcsOverride: ecs_entity_t;

pub extern const EcsInherit: ecs_entity_t;

pub extern const EcsDontInherit: ecs_entity_t;

/// Mark a relationship as reflexive: `R(X, X)` holds for every `X`, without the pair
/// having to be added.
pub extern const EcsReflexive: ecs_entity_t;

/// Mark component as inheritable. This is the opposite of Final. This trait can be used
/// to enforce that queries take into account component inheritance before inheritance
/// (IsA) relationships are added with the component as the target.
pub extern const EcsInheritable: ecs_entity_t;

/// Mark a relationship as symmetric: adding `R(X, Y)` adds `R(Y, X)` too.
pub extern const EcsSymmetric: ecs_entity_t;

/// Mark a relationship as acyclic. Acyclic relationships may not form cycles.
pub extern const EcsAcyclic: ecs_entity_t;

/// Ensure that a component is always added together with another component.
pub extern const EcsWith: ecs_entity_t;

/// Ensure that a relationship target is a child of the specified entity.
pub extern const EcsOneOf: ecs_entity_t;

/// Mark a component as toggleable with ecs_enable_id().
pub extern const EcsCanToggle: ecs_entity_t;

/// Can be added to components to indicate it is a trait. Traits are components and/or
/// tags that are added to other components to modify their behavior.
pub extern const EcsTrait: ecs_entity_t;

/// Ensure that an entity is always used in a pair as a relationship.
pub extern const EcsRelationship: ecs_entity_t;

/// Ensure that an entity is always used in a pair as a target.
pub extern const EcsTarget: ecs_entity_t;

/// Can be added to a relationship to indicate that it should never hold data, even when
/// it or the relationship target is a component.
pub extern const EcsPairIsTag: ecs_entity_t;

pub extern const EcsName: ecs_entity_t;

pub extern const EcsSymbol: ecs_entity_t;

pub extern const EcsChildOf: ecs_entity_t;

pub extern const EcsIsA: ecs_entity_t;

pub extern const EcsDependsOn: ecs_entity_t;

pub extern const EcsSlotOf: ecs_entity_t;

pub extern const EcsModule: ecs_entity_t;

pub extern const EcsPrefab: ecs_entity_t;

pub extern const EcsDisabled: ecs_entity_t;

pub extern const EcsEmpty: ecs_entity_t;

/// Tag to indicate alias identifier.
pub extern const EcsAlias: ecs_entity_t;

/// Tag that, when added to a parent, ensures stable order of ecs_children() results.
pub extern const EcsOrderedChildren: ecs_entity_t;

/// Trait added to entities that should never be returned by queries. Reserved for
/// internal entities that have special meaning to the query engine, such as #EcsThis,
/// #EcsWildcard, #EcsAny.
pub extern const EcsNotQueryable: ecs_entity_t;

pub extern const EcsOnAdd: ecs_entity_t;

pub extern const EcsOnRemove: ecs_entity_t;

pub extern const EcsOnSet: ecs_entity_t;

pub extern const EcsMonitor: ecs_entity_t;

pub extern const EcsOnTableCreate: ecs_entity_t;

pub extern const EcsOnDelete: ecs_entity_t;

/// Event that triggers when a table is deleted.
pub extern const EcsOnTableDelete: ecs_entity_t;

/// Relationship used to define what should happen when a target entity (second element
/// of a pair) is deleted.
pub extern const EcsOnDeleteTarget: ecs_entity_t;

/// Remove cleanup policy. Must be used as a target in a pair with #EcsOnDelete or
/// #EcsOnDeleteTarget.
pub extern const EcsRemove: ecs_entity_t;

/// Delete cleanup policy. Must be used as a target in a pair with #EcsOnDelete or
/// #EcsOnDeleteTarget.
pub extern const EcsDelete: ecs_entity_t;

/// Panic cleanup policy. Must be used as a target in a pair with #EcsOnDelete or
/// #EcsOnDeleteTarget.
pub extern const EcsPanic: ecs_entity_t;

/// Mark component as singleton. Singleton components may only be added to themselves.
pub extern const EcsSingleton: ecs_entity_t;

/// Mark component as non-fragmenting.
pub extern const EcsDontFragment: ecs_entity_t;

/// Marker used to indicate `$var == ...` matching in queries.
pub extern const EcsPredEq: ecs_entity_t;

/// Marker used to indicate `$var == "name"` matching in queries.
pub extern const EcsPredMatch: ecs_entity_t;

/// Marker used to indicate `$var ~= "pattern"` matching in queries.
pub extern const EcsPredLookup: ecs_entity_t;

/// Marker used to indicate the start of a scope (`{`) in queries.
pub extern const EcsScopeOpen: ecs_entity_t;

/// Built-in pipeline phase run at startup.
pub extern const EcsOnStart: ecs_entity_t;

/// Built-in Constant tag.
pub extern const EcsConstant: ecs_entity_t;

pub const ecs_http_connection_t = extern struct {
    id: u64 = 0,
    server: ?*ecs_http_server_t = null,
    host: [128]u8 = @splat(0),
    port: [16]u8 = @splat(0),
};

pub const ecs_http_key_value_t = extern struct {
    key: ?[*:0]const u8 = null,
    value: ?[*:0]const u8 = null,
};

pub const ecs_http_method_t = c_uint;

pub const ecs_http_request_t = extern struct {
    id: u64 = 0,
    method: ecs_http_method_t = 0,
    path: ?[*:0]u8 = null,
    body: ?[*:0]u8 = null,
    headers: [32]ecs_http_key_value_t = @splat(.{}),
    params: [32]ecs_http_key_value_t = @splat(.{}),
    header_count: i32 = 0,
    param_count: i32 = 0,
    conn: ?*ecs_http_connection_t = null,
};

pub const ecs_http_reply_t = extern struct {
    code: c_int = 0,
    body: ecs_strbuf_t = .{},
    status: ?[*:0]const u8 = null,
    content_type: ?[*:0]const u8 = null,
    headers: ecs_strbuf_t = .{},
};

pub const ecs_http_server_desc_t = extern struct {
    callback: ecs_http_reply_action_t = null,
    ctx: ?*anyopaque = null,
    port: u16 = 0,
    ipaddr: ?[*:0]const u8 = null,
    send_queue_wait_ms: i32 = 0,
    cache_timeout: f64 = 0,
    cache_purge_timeout: f64 = 0,
};

/// Set this on an entity and flecs starts a REST server for the Explorer to connect to.
pub const EcsRest = extern struct {
    port: u16 = 0,
    ipaddr: ?[*:0]u8 = null,
    impl: ?*ecs_rest_ctx_t = null,
};

/// Private state the REST addon hangs off an `EcsRest` component. flecs keeps the type
/// incomplete to callers, and there is nothing here a consumer would want to read.
pub const ecs_rest_ctx_t = opaque {};

pub const ecs_entities_memory_t = extern struct {
    alive_count: i32 = 0,
    not_alive_count: i32 = 0,
    bytes_entity_index: ecs_size_t = 0,
    bytes_names: ecs_size_t = 0,
    bytes_doc_strings: ecs_size_t = 0,
};

pub const ecs_component_index_memory_t = extern struct {
    count: i32 = 0,
    bytes_component_record: ecs_size_t = 0,
    bytes_table_cache: ecs_size_t = 0,
    bytes_name_index: ecs_size_t = 0,
    bytes_ordered_children: ecs_size_t = 0,
    bytes_children_table_map: ecs_size_t = 0,
    bytes_reachable_cache: ecs_size_t = 0,
};

pub const ecs_query_memory_t = extern struct {
    count: i32 = 0,
    cached_count: i32 = 0,
    bytes_query: ecs_size_t = 0,
    bytes_cache: ecs_size_t = 0,
    bytes_group_by: ecs_size_t = 0,
    bytes_order_by: ecs_size_t = 0,
    bytes_plan: ecs_size_t = 0,
    bytes_terms: ecs_size_t = 0,
    bytes_misc: ecs_size_t = 0,
};

pub const ecs_component_memory_t = extern struct {
    instances: i32 = 0,
    bytes_table_components: ecs_size_t = 0,
    bytes_table_components_unused: ecs_size_t = 0,
    bytes_toggle_bitsets: ecs_size_t = 0,
    bytes_sparse_components: ecs_size_t = 0,
};

pub const ecs_table_memory_t = extern struct {
    count: i32 = 0,
    empty_count: i32 = 0,
    column_count: i32 = 0,
    bytes_table: ecs_size_t = 0,
    bytes_type: ecs_size_t = 0,
    bytes_entities: ecs_size_t = 0,
    bytes_overrides: ecs_size_t = 0,
    bytes_column_map: ecs_size_t = 0,
    bytes_component_map: ecs_size_t = 0,
    bytes_dirty_state: ecs_size_t = 0,
    bytes_edges: ecs_size_t = 0,
};

pub const ecs_misc_memory_t = extern struct {
    bytes_world: ecs_size_t = 0,
    bytes_observers: ecs_size_t = 0,
    bytes_systems: ecs_size_t = 0,
    bytes_pipelines: ecs_size_t = 0,
    bytes_table_lookup: ecs_size_t = 0,
    bytes_component_record_lookup: ecs_size_t = 0,
    bytes_locked_components: ecs_size_t = 0,
    bytes_type_info: ecs_size_t = 0,
    bytes_commands: ecs_size_t = 0,
    bytes_rematch_monitor: ecs_size_t = 0,
    bytes_component_ids: ecs_size_t = 0,
    bytes_reflection: ecs_size_t = 0,
    bytes_tree_spawner: ecs_size_t = 0,
    bytes_prefab_child_indices: ecs_size_t = 0,
    bytes_stats: ecs_size_t = 0,
    bytes_rest: ecs_size_t = 0,
};

pub const ecs_table_histogram_t = extern struct {
    entity_counts: [14]i32 = @splat(0),
};

pub const ecs_allocator_memory_t = extern struct {
    bytes_graph_edge: ecs_size_t = 0,
    bytes_component_record: ecs_size_t = 0,
    bytes_pair_record: ecs_size_t = 0,
    bytes_table_diff: ecs_size_t = 0,
    bytes_sparse_chunk: ecs_size_t = 0,
    bytes_allocator: ecs_size_t = 0,
    bytes_stack_allocator: ecs_size_t = 0,
    bytes_cmd_entry_chunk: ecs_size_t = 0,
    bytes_query_impl: ecs_size_t = 0,
    bytes_query_cache: ecs_size_t = 0,
    bytes_misc: ecs_size_t = 0,
};

pub extern var EcsUnitPrefixes: ecs_entity_t;

pub extern var EcsYocto: ecs_entity_t;

pub extern var EcsZepto: ecs_entity_t;

pub extern var EcsAtto: ecs_entity_t;

pub extern var EcsFemto: ecs_entity_t;

pub extern var EcsPico: ecs_entity_t;

pub extern var EcsNano: ecs_entity_t;

pub extern var EcsMicro: ecs_entity_t;

pub extern var EcsMilli: ecs_entity_t;

pub extern var EcsCenti: ecs_entity_t;

pub extern var EcsDeci: ecs_entity_t;

pub extern var EcsDeca: ecs_entity_t;

pub extern var EcsHecto: ecs_entity_t;

pub extern var EcsKilo: ecs_entity_t;

pub extern var EcsMega: ecs_entity_t;

pub extern var EcsGiga: ecs_entity_t;

pub extern var EcsTera: ecs_entity_t;

pub extern var EcsPeta: ecs_entity_t;

pub extern var EcsExa: ecs_entity_t;

pub extern var EcsZetta: ecs_entity_t;

pub extern var EcsYotta: ecs_entity_t;

pub extern var EcsKibi: ecs_entity_t;

pub extern var EcsMebi: ecs_entity_t;

pub extern var EcsGibi: ecs_entity_t;

pub extern var EcsTebi: ecs_entity_t;

pub extern var EcsPebi: ecs_entity_t;

pub extern var EcsExbi: ecs_entity_t;

pub extern var EcsZebi: ecs_entity_t;

pub extern var EcsYobi: ecs_entity_t;

pub extern var EcsDuration: ecs_entity_t;

pub extern var EcsPicoSeconds: ecs_entity_t;

pub extern var EcsNanoSeconds: ecs_entity_t;

pub extern var EcsMicroSeconds: ecs_entity_t;

pub extern var EcsMilliSeconds: ecs_entity_t;

pub extern var EcsSeconds: ecs_entity_t;

pub extern var EcsMinutes: ecs_entity_t;

pub extern var EcsHours: ecs_entity_t;

pub extern var EcsDays: ecs_entity_t;

pub extern var EcsTime: ecs_entity_t;

pub extern var EcsDate: ecs_entity_t;

pub extern var EcsMass: ecs_entity_t;

pub extern var EcsGrams: ecs_entity_t;

pub extern var EcsKiloGrams: ecs_entity_t;

pub extern var EcsElectricCurrent: ecs_entity_t;

pub extern var EcsAmpere: ecs_entity_t;

pub extern var EcsAmount: ecs_entity_t;

pub extern var EcsMole: ecs_entity_t;

pub extern var EcsLuminousIntensity: ecs_entity_t;

pub extern var EcsCandela: ecs_entity_t;

pub extern var EcsForce: ecs_entity_t;

pub extern var EcsNewton: ecs_entity_t;

pub extern var EcsLength: ecs_entity_t;

pub extern var EcsMeters: ecs_entity_t;

pub extern var EcsPicoMeters: ecs_entity_t;

pub extern var EcsNanoMeters: ecs_entity_t;

pub extern var EcsMicroMeters: ecs_entity_t;

pub extern var EcsMilliMeters: ecs_entity_t;

pub extern var EcsCentiMeters: ecs_entity_t;

pub extern var EcsKiloMeters: ecs_entity_t;

pub extern var EcsMiles: ecs_entity_t;

pub extern var EcsPixels: ecs_entity_t;

pub extern var EcsPressure: ecs_entity_t;

pub extern var EcsPascal: ecs_entity_t;

pub extern var EcsBar: ecs_entity_t;

pub extern var EcsSpeed: ecs_entity_t;

pub extern var EcsMetersPerSecond: ecs_entity_t;

pub extern var EcsKiloMetersPerSecond: ecs_entity_t;

pub extern var EcsKiloMetersPerHour: ecs_entity_t;

pub extern var EcsMilesPerHour: ecs_entity_t;

pub extern var EcsTemperature: ecs_entity_t;

pub extern var EcsKelvin: ecs_entity_t;

pub extern var EcsCelsius: ecs_entity_t;

pub extern var EcsFahrenheit: ecs_entity_t;

pub extern var EcsData: ecs_entity_t;

pub extern var EcsBits: ecs_entity_t;

pub extern var EcsKiloBits: ecs_entity_t;

pub extern var EcsMegaBits: ecs_entity_t;

pub extern var EcsGigaBits: ecs_entity_t;

pub extern var EcsBytes: ecs_entity_t;

pub extern var EcsKiloBytes: ecs_entity_t;

pub extern var EcsMegaBytes: ecs_entity_t;

pub extern var EcsGigaBytes: ecs_entity_t;

pub extern var EcsKibiBytes: ecs_entity_t;

pub extern var EcsMebiBytes: ecs_entity_t;

pub extern var EcsGibiBytes: ecs_entity_t;

pub extern var EcsDataRate: ecs_entity_t;

pub extern var EcsBitsPerSecond: ecs_entity_t;

pub extern var EcsKiloBitsPerSecond: ecs_entity_t;

pub extern var EcsMegaBitsPerSecond: ecs_entity_t;

pub extern var EcsGigaBitsPerSecond: ecs_entity_t;

pub extern var EcsBytesPerSecond: ecs_entity_t;

pub extern var EcsKiloBytesPerSecond: ecs_entity_t;

pub extern var EcsMegaBytesPerSecond: ecs_entity_t;

pub extern var EcsGigaBytesPerSecond: ecs_entity_t;

pub extern var EcsAngle: ecs_entity_t;

pub extern var EcsRadians: ecs_entity_t;

pub extern var EcsDegrees: ecs_entity_t;

pub extern var EcsFrequency: ecs_entity_t;

pub extern var EcsHertz: ecs_entity_t;

pub extern var EcsKiloHertz: ecs_entity_t;

pub extern var EcsMegaHertz: ecs_entity_t;

pub extern var EcsGigaHertz: ecs_entity_t;

pub extern var EcsUri: ecs_entity_t;

pub extern var EcsUriHyperlink: ecs_entity_t;

pub extern var EcsUriImage: ecs_entity_t;

pub extern var EcsUriFile: ecs_entity_t;

pub extern var EcsColor: ecs_entity_t;

pub extern var EcsColorRgb: ecs_entity_t;

pub extern var EcsColorHsl: ecs_entity_t;

pub extern var EcsColorCss: ecs_entity_t;

pub extern var EcsAcceleration: ecs_entity_t;

pub extern var EcsPercentage: ecs_entity_t;

pub extern var EcsBel: ecs_entity_t;

pub extern var EcsDeciBel: ecs_entity_t;

/// Import the units module, which registers `EcsMeters`, `EcsSeconds` and the rest of
/// the quantities and prefixes below. Needs the meta and units addons.
pub extern fn FlecsUnitsImport(world: *ecs_world_t) void;

pub extern var FLECS_IDEcsAlertCriticalID_: ecs_entity_t;

pub extern var FLECS_IDEcsAlertErrorID_: ecs_entity_t;

pub extern var FLECS_IDEcsAlertID_: ecs_entity_t;

pub extern var FLECS_IDEcsAlertInfoID_: ecs_entity_t;

pub extern var FLECS_IDEcsAlertInstanceID_: ecs_entity_t;

pub extern var FLECS_IDEcsAlertTimeoutID_: ecs_entity_t;

pub extern var FLECS_IDEcsAlertWarningID_: ecs_entity_t;

pub extern var FLECS_IDEcsAlertsActiveID_: ecs_entity_t;

pub extern const FLECS_IDEcsArrayID_: ecs_entity_t;

pub extern const FLECS_IDEcsBitmaskID_: ecs_entity_t;

pub extern const FLECS_IDEcsComponentID_: ecs_entity_t;

pub extern const FLECS_IDEcsConstantsID_: ecs_entity_t;

pub extern var FLECS_IDEcsCounterID_: ecs_entity_t;

pub extern var FLECS_IDEcsCounterIdID_: ecs_entity_t;

pub extern var FLECS_IDEcsCounterIncrementID_: ecs_entity_t;

pub extern const FLECS_IDEcsDefaultChildComponentID_: ecs_entity_t;

pub extern const FLECS_IDEcsDocDescriptionID_: ecs_entity_t;

pub extern const FLECS_IDEcsEnumID_: ecs_entity_t;

pub extern var FLECS_IDEcsGaugeID_: ecs_entity_t;

pub extern const FLECS_IDEcsIdentifierID_: ecs_entity_t;

pub extern const FLECS_IDEcsMemberID_: ecs_entity_t;

pub extern const FLECS_IDEcsMemberRangesID_: ecs_entity_t;

pub extern var FLECS_IDEcsMetricID_: ecs_entity_t;

pub extern var FLECS_IDEcsMetricInstanceID_: ecs_entity_t;

pub extern var FLECS_IDEcsMetricSourceID_: ecs_entity_t;

pub extern var FLECS_IDEcsMetricValueID_: ecs_entity_t;

pub extern const FLECS_IDEcsOpaqueID_: ecs_entity_t;

pub extern const FLECS_IDEcsParentID_: ecs_entity_t;

pub extern const FLECS_IDEcsPipelineID_: ecs_entity_t;

pub extern const FLECS_IDEcsPipelineQueryID_: ecs_entity_t;

pub extern var FLECS_IDEcsPipelineStatsID_: ecs_entity_t;

pub extern const FLECS_IDEcsPolyID_: ecs_entity_t;

pub extern const FLECS_IDEcsPrimitiveID_: ecs_entity_t;

pub extern const FLECS_IDEcsRateFilterID_: ecs_entity_t;

/// `ecs_id(EcsRest)` — the id of the component that starts a REST server when set.
pub extern const FLECS_IDEcsRestID_: ecs_entity_t;

pub extern var FLECS_IDEcsScriptConstVarID_: ecs_entity_t;

pub extern var FLECS_IDEcsScriptFunctionID_: ecs_entity_t;

pub extern var FLECS_IDEcsScriptID_: ecs_entity_t;

pub extern var FLECS_IDEcsScriptMethodID_: ecs_entity_t;

pub extern var FLECS_IDEcsScriptRngID_: ecs_entity_t;

pub extern var FLECS_IDEcsScriptTemplateID_: ecs_entity_t;

pub extern var FLECS_IDEcsScriptVectorTypeID_: ecs_entity_t;

pub extern const FLECS_IDEcsStructID_: ecs_entity_t;

pub extern var FLECS_IDEcsSystemStatsID_: ecs_entity_t;

pub extern const FLECS_IDEcsTickSourceID_: ecs_entity_t;

pub extern const FLECS_IDEcsTimerID_: ecs_entity_t;

pub extern const FLECS_IDEcsTreeSpawnerID_: ecs_entity_t;

pub extern const FLECS_IDEcsTypeID_: ecs_entity_t;

pub extern const FLECS_IDEcsTypeSerializerID_: ecs_entity_t;

pub extern const FLECS_IDEcsUnitID_: ecs_entity_t;

pub extern const FLECS_IDEcsUnitPrefixID_: ecs_entity_t;

pub extern const FLECS_IDEcsVectorID_: ecs_entity_t;

pub extern var FLECS_IDEcsWorldMemoryID_: ecs_entity_t;

pub extern var FLECS_IDEcsWorldStatsID_: ecs_entity_t;

pub extern var FLECS_IDEcsWorldSummaryID_: ecs_entity_t;

pub extern var FLECS_IDFlecsAlertsID_: ecs_entity_t;

pub extern var FLECS_IDFlecsMetricsID_: ecs_entity_t;

pub extern var FLECS_IDFlecsStatsID_: ecs_entity_t;

pub extern var FLECS_IDecs_allocator_memory_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_bool_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_byte_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_char_tID_: ecs_entity_t;

pub extern var FLECS_IDecs_component_index_memory_tID_: ecs_entity_t;

pub extern var FLECS_IDecs_component_memory_tID_: ecs_entity_t;

pub extern var FLECS_IDecs_entities_memory_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_entity_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_f32_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_f64_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_i16_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_i32_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_i64_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_i8_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_id_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_iptr_tID_: ecs_entity_t;

pub extern var FLECS_IDecs_misc_memory_tID_: ecs_entity_t;

pub extern var FLECS_IDecs_query_memory_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_string_tID_: ecs_entity_t;

pub extern var FLECS_IDecs_table_histogram_tID_: ecs_entity_t;

pub extern var FLECS_IDecs_table_memory_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_u16_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_u32_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_u64_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_u8_tID_: ecs_entity_t;

pub extern const FLECS_IDecs_uptr_tID_: ecs_entity_t;

/// Marker used to indicate the end of a scope (`}`) in queries.
pub extern const EcsScopeClose: ecs_entity_t;

pub extern const EcsPreFrame: ecs_entity_t;

pub extern const EcsOnLoad: ecs_entity_t;

pub extern const EcsPostLoad: ecs_entity_t;

pub extern const EcsPreUpdate: ecs_entity_t;

pub extern const EcsOnUpdate: ecs_entity_t;

pub extern const EcsOnValidate: ecs_entity_t;

pub extern const EcsPostUpdate: ecs_entity_t;

pub extern const EcsPreStore: ecs_entity_t;

pub extern const EcsOnStore: ecs_entity_t;

pub extern const EcsPostFrame: ecs_entity_t;

pub extern const EcsPhase: ecs_entity_t;

pub extern fn ecs_entity_init(world: *ecs_world_t, desc: *const ecs_entity_desc_t) ecs_entity_t;

pub extern fn ecs_component_init(world: *ecs_world_t, desc: *const ecs_component_desc_t) ecs_entity_t;

pub extern fn ecs_set_id(world: *ecs_world_t, entity: ecs_entity_t, id: ecs_id_t, size: usize, ptr: ?*const anyopaque) void;

pub extern fn ecs_has_id(world: *const ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) bool;

/// Render an id: `Position`, `(ChildOf, parent)`, or either with a `FLAG|` in front. The
/// `PAIR` flag is left implicit. Free the result with `ecs_os_free`.
pub extern fn ecs_id_str(world: *const ecs_world_t, component: ecs_id_t) ?[*:0]u8;

pub const ecs_query_op_ctx_t = opaque {};

pub const ecs_query_op_t = opaque {};

pub const ecs_query_var_t = opaque {};

/// Create a query. Null when the descriptor is invalid. If `desc.entity` names an
/// existing entity, that entity must not already hold a query; `ecs_query_update`
/// replaces one.
pub extern fn ecs_query_init(world: *ecs_world_t, desc: *const ecs_query_desc_t) ?*ecs_query_t;

/// `ECS_GENERATION(e)` — the generation an entity id carries.
pub inline fn ECS_GENERATION(e: ecs_entity_t) u64 {
    return (e & ECS_GENERATION_MASK) >> 32;
}

/// `ECS_GENERATION_INC(e)` — the same entity, one generation on.
pub inline fn ECS_GENERATION_INC(e: ecs_entity_t) ecs_entity_t {
    return (e & ~ECS_GENERATION_MASK) | ((0xFFFF & (ECS_GENERATION(e) +% 1)) << 32);
}

/// `ECS_IS_PAIR(id)` — whether an id is a pair. Both flavours count: a value pair
/// carries its own flag bit, and forgetting it is a bug flecs's own macro does not
/// have.
pub inline fn ECS_IS_PAIR(id: ecs_id_t) bool {
    return (id & ECS_ID_FLAGS_MASK) == ECS_PAIR or ECS_IS_VALUE_PAIR(id);
}

/// `ECS_IS_VALUE_PAIR(id)`
pub inline fn ECS_IS_VALUE_PAIR(id: ecs_id_t) bool {
    return (id & ECS_ID_FLAGS_MASK) == ECS_VALUE_PAIR;
}

/// `ECS_PAIR_FIRST(e)` — the relationship of a pair.
pub inline fn ECS_PAIR_FIRST(e: ecs_id_t) ecs_entity_t {
    return ecs_entity_t_hi(e & ECS_COMPONENT_MASK);
}

/// `ECS_PAIR_SECOND(e)` — the target of a pair.
pub inline fn ECS_PAIR_SECOND(e: ecs_id_t) ecs_entity_t {
    return ecs_entity_t_lo(e);
}

/// `ecs_entity_t_comb(lo, hi)`
pub inline fn ecs_entity_t_comb(lo: u64, hi: u64) u64 {
    return (hi << 32) +% ecs_entity_t_lo(lo);
}

/// `ecs_entity_t_hi(value)`
pub inline fn ecs_entity_t_hi(value: u64) u32 {
    return @truncate(value >> 32);
}

/// `ecs_entity_t_lo(value)`
pub inline fn ecs_entity_t_lo(value: u64) u32 {
    return @truncate(value);
}

/// `ecs_pair(rel, tgt)` — the id of a relationship pair.
pub inline fn ecs_pair(rel: ecs_entity_t, tgt: ecs_entity_t) ecs_id_t {
    return ECS_PAIR | ecs_entity_t_comb(tgt, rel);
}

/// `ecs_value_pair(rel, val)` — the id of a pair whose target is a value rather than
/// an entity.
pub inline fn ecs_value_pair(rel: ecs_entity_t, val: ecs_entity_t) ecs_id_t {
    return ECS_VALUE_PAIR | ecs_entity_t_comb(val, rel);
}

/// `va_list`, for the six entry points that take one — as it is PASSED, which on
/// x86_64 System V is not the object type `std.builtin.VaList` names, and on x86_64
/// Windows is a type `std` refuses to give at all (zig 0.16.0,
/// `lib/std/builtin.zig:1053`: `@compileError("disabled due to miscompilations")`).
/// The derivation and the reasons for all three shapes are in `src/c/abi.zig`, and
/// `src/abi_check.zig` proves the choice against `@cImport` on the target being built.
pub const va_list = abi.va_list;

pub const ecs_app_init_action_t = ?*const fn (world: *ecs_world_t) callconv(.c) c_int;

pub const ecs_app_desc_t = extern struct {
    target_fps: ecs_ftime_t = 0,
    delta_time: ecs_ftime_t = 0,
    threads: i32 = 0,
    frames: i32 = 0,
    enable_rest: bool = false,
    enable_stats: bool = false,
    port: u16 = 0,
    init: ecs_app_init_action_t = null,
    ctx: ?*anyopaque = null,
};

/// Run the application's main loop, then destroy the world. Calls the run action, which
/// by default calls the frame action until it returns nonzero. `ecs_quit` is what ends
/// it. The world is gone when this returns, so nothing that points into it survives.
pub extern fn ecs_app_run(world: *ecs_world_t, desc: *ecs_app_desc_t) c_int;

/// HTTP server.
pub const ecs_http_server_t = opaque {};

pub const ecs_http_reply_action_t = ?*const fn (request: ?*const ecs_http_request_t, reply: ?*ecs_http_reply_t, ctx: ?*anyopaque) callconv(.c) bool;

/// Start accepting requests. Needs an OS API with threading; nonzero if it could not
/// start.
pub extern fn ecs_http_server_start(server: *ecs_http_server_t) c_int;

/// Run the reply callback for each request received since the last call. No new requests
/// are enqueued while this runs, so the callback sees a stable set.
pub extern fn ecs_http_server_dequeue(server: *ecs_http_server_t, delta_time: ecs_ftime_t) void;

/// Create an HTTP server serving the REST API, for an application that wants to drive
/// it itself rather than through the `EcsRest` component and the flecs systems behind
/// it. Null if the server could not be created.
pub extern fn ecs_rest_server_init(world: *ecs_world_t, desc: *const ecs_http_server_desc_t) ?*ecs_http_server_t;

/// Destroy a server created with `ecs_rest_server_init`. Not interchangeable with
/// `ecs_http_server_fini`, which leaks the REST context this one frees.
pub extern fn ecs_rest_server_fini(srv: *ecs_http_server_t) void;

pub extern fn ecs_get_pipeline(world: *const ecs_world_t) ecs_entity_t;

pub const ecs_system_desc_t = extern struct {
    _canary: i32 = 0,
    entity: ecs_entity_t = 0,
    query: ecs_query_desc_t = .{},
    phase: ecs_entity_t = 0,
    callback: ecs_iter_action_t = null,
    run: ecs_run_action_t = null,
    ctx: ?*anyopaque = null,
    ctx_free: ecs_ctx_free_t = null,
    callback_ctx: ?*anyopaque = null,
    callback_ctx_free: ecs_ctx_free_t = null,
    run_ctx: ?*anyopaque = null,
    run_ctx_free: ecs_ctx_free_t = null,
    interval: ecs_ftime_t = 0,
    rate: i32 = 0,
    tick_source: ecs_entity_t = 0,
    multi_threaded: bool = false,
    immediate: bool = false,
};

/// Import the stats module, the equivalent of `ECS_IMPORT(world, FlecsStats)` in C.
pub extern fn FlecsStatsImport(world: *ecs_world_t) void;

/// Serialize one value to JSON, the same as `ecs_array_to_json` with count 0. Free the
/// result with `ecs_os_free`.
pub extern fn ecs_ptr_to_json(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque) ?[*:0]u8;

/// One of the `EcsBool`..`EcsId` constants. Declared as the integer the C enum compiles
/// to, for the same reason as `ecs_type_kind_t`.
pub const ecs_primitive_kind_t = c_uint;

pub const ecs_member_value_range_t = extern struct {
    min: f64 = 0,
    max: f64 = 0,
};

/// One member of a struct: the element type of `EcsStruct.members`, and what
/// `ecs_struct_desc_t` is filled with. The trailing fields are out-only.
pub const ecs_member_t = extern struct {
    /// Required in `ecs_struct_desc_t`.
    name: ?[*:0]const u8 = null,
    type: ecs_entity_t = 0,
    /// Element count for an inline array member, 0 otherwise.
    count: i32 = 0,
    offset: i32 = 0,
    /// Filled in automatically when the member's type entity is also a unit.
    unit: ecs_entity_t = 0,
    /// Use `offset` as given instead of computing it, which is what members registered
    /// out of order, or with offsets the C layout does not produce, need.
    use_offset: bool = false,
    range: ecs_member_value_range_t = .{},
    error_range: ecs_member_value_range_t = .{},
    warning_range: ecs_member_value_range_t = .{},
    /// Set by flecs. Do not set in `ecs_struct_desc_t`.
    size: ecs_size_t = 0,
    /// Set by flecs. Do not set in `ecs_struct_desc_t`.
    member: ecs_entity_t = 0,
};

/// Added to enum type entities.
pub const EcsEnum = extern struct {
    underlying_type: ecs_entity_t = 0,
};

pub const ecs_bitmask_constant_t = extern struct {
    /// Required in `ecs_bitmask_desc_t`.
    name: ?[*:0]const u8 = null,
    value: ecs_flags64_t = 0,
    /// Padding that keeps this type's layout equal to `ecs_enum_constant_t`.
    _unused: i64 = 0,
    /// Set by flecs. Do not set in `ecs_bitmask_desc_t`.
    constant: ecs_entity_t = 0,
};

/// What an opaque type's `serialize` callback writes through. Call `value` for a value of
/// a known type, and `member` before each member of a struct.
pub const ecs_serializer_t = extern struct {
    value: ?*const fn (ser: *const ecs_serializer_t, @"type": ecs_entity_t, value: ?*const anyopaque) callconv(.c) c_int = null,
    member: ?*const fn (ser: *const ecs_serializer_t, member: ?[*:0]const u8) callconv(.c) c_int = null,
    world: ?*const ecs_world_t = null,
    ctx: ?*anyopaque = null,
};

/// Serializer function, used to serialize opaque types.
pub const ecs_meta_serialize_t = ?*const fn (ser: *const ecs_serializer_t, src: ?*const anyopaque) callconv(.c) c_int;

pub const ecs_meta_serialize_member_t = ?*const fn (ser: *const ecs_serializer_t, src: ?*const anyopaque, name: ?[*:0]const u8) callconv(.c) c_int;

pub const ecs_meta_serialize_element_t = ?*const fn (ser: *const ecs_serializer_t, src: ?*const anyopaque, elem: usize) callconv(.c) c_int;

/// Reflection data for a type whose layout the meta framework cannot describe, mapped
/// onto one it can. Set only the callbacks that make sense for the type; a deserializer
/// that reaches for one that is null reports a conversion error.
pub const EcsOpaque = extern struct {
    /// The type whose shape the serialized form has.
    as_type: ecs_entity_t = 0,
    serialize: ecs_meta_serialize_t = null,
    serialize_member: ecs_meta_serialize_member_t = null,
    serialize_element: ecs_meta_serialize_element_t = null,
    assign_bool: ?*const fn (dst: ?*anyopaque, value: bool) callconv(.c) void = null,
    assign_char: ?*const fn (dst: ?*anyopaque, value: u8) callconv(.c) void = null,
    assign_int: ?*const fn (dst: ?*anyopaque, value: i64) callconv(.c) void = null,
    assign_uint: ?*const fn (dst: ?*anyopaque, value: u64) callconv(.c) void = null,
    assign_float: ?*const fn (dst: ?*anyopaque, value: f64) callconv(.c) void = null,
    assign_string: ?*const fn (dst: ?*anyopaque, value: ?[*:0]const u8) callconv(.c) void = null,
    assign_entity: ?*const fn (dst: ?*anyopaque, world: ?*ecs_world_t, entity: ecs_entity_t) callconv(.c) void = null,
    assign_id: ?*const fn (dst: ?*anyopaque, world: ?*ecs_world_t, id: ecs_id_t) callconv(.c) void = null,
    assign_null: ?*const fn (dst: ?*anyopaque) callconv(.c) void = null,
    clear: ?*const fn (dst: ?*anyopaque) callconv(.c) void = null,
    ensure_element: ?*const fn (dst: ?*anyopaque, elem: usize) callconv(.c) ?*anyopaque = null,
    ensure_member: ?*const fn (dst: ?*anyopaque, member: ?[*:0]const u8) callconv(.c) ?*anyopaque = null,
    count: ?*const fn (dst: ?*const anyopaque) callconv(.c) usize = null,
    resize: ?*const fn (dst: ?*anyopaque, count: usize) callconv(.c) void = null,
};

pub const ecs_primitive_desc_t = extern struct {
    /// Existing entity to attach the type to. 0 creates one.
    entity: ecs_entity_t = 0,
    kind: ecs_primitive_kind_t = 0,
};

/// Register a primitive type. 0 on failure. This and the other `ecs_*_init` operations
/// below are what flecs's `ecs_primitive`, `ecs_enum` and friends expand to.
pub extern fn ecs_primitive_init(world: *ecs_world_t, desc: *const ecs_primitive_desc_t) ecs_entity_t;

pub const ecs_bitmask_desc_t = extern struct {
    /// Existing entity to attach the type to. 0 creates one.
    entity: ecs_entity_t = 0,
    /// Terminated by the first entry with a null name.
    constants: [32]ecs_bitmask_constant_t = @splat(.{}),
};

/// Register a bitmask type. 0 on failure.
pub extern fn ecs_bitmask_init(world: *ecs_world_t, desc: *const ecs_bitmask_desc_t) ecs_entity_t;

pub const ecs_array_desc_t = extern struct {
    /// Existing entity to attach the type to. 0 creates one.
    entity: ecs_entity_t = 0,
    type: ecs_entity_t = 0,
    count: i32 = 0,
};

/// Register a fixed-size array type. 0 on failure.
pub extern fn ecs_array_init(world: *ecs_world_t, desc: *const ecs_array_desc_t) ecs_entity_t;

/// Append a member to a struct type, adding the `EcsStruct` component first if the
/// entity is not a struct type yet.
pub extern fn ecs_struct_add_member(world: *ecs_world_t, @"type": ecs_entity_t, member: *const ecs_member_t) c_int;

pub const ecs_opaque_desc_t = extern struct {
    /// Existing entity to attach the type to. 0 creates one.
    entity: ecs_entity_t = 0,
    type: EcsOpaque = .{},
};

/// Register an opaque type: one whose layout the meta primitives cannot describe, but
/// whose contents can be reached through callbacks and presented as a type they can. A
/// container with private storage, or a type behind getters and setters, is the case
/// this exists for. 0 on failure.
pub extern fn ecs_opaque_init(world: *ecs_world_t, desc: *const ecs_opaque_desc_t) ecs_entity_t;
