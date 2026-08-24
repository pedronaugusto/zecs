//! Hand-written declarations mirroring `libs/flecs/flecs.h`.
//!
//! ## Why hand-written
//!
//! These are written out rather than produced by `@cImport` so that the package stays
//! translate-c free, every type is exactly the shape the rest of the wrapper wants, and
//! the declarations can be read as documentation of the boundary. translate-c would
//! render every pointer as `[*c]T` — an unknown quantity that is neither optional nor
//! non-optional nor a slice — and that is precisely the information worth having.
//!
//! The cost of hand-writing is drift: nothing in either compiler checks that this file
//! still agrees with the header. `abi_check.zig` closes that gap, comparing every
//! declaration here against a `@cImport` of the real header at compile time. A field
//! reordered on one side and not the other fails the build instead of corrupting memory.
//!
//! ## Naming
//!
//! Names here are flecs's own, verbatim: `ecs_world_t`, `ecs_entity_init`, `EcsOnUpdate`,
//! `ECS_PAIR`. Zig would normally spell some of them differently, but this is the raw
//! layer — its whole purpose is that C documentation, C examples and C answers apply to
//! it unchanged. The idiomatic surface lives one level up, in `zecs` itself.
//!
//! Verbatim includes the macros rewritten as functions at the bottom of this file: they
//! keep the macro's name, not a Zig spelling of it. flecs has more than one name for
//! things that are nearly-but-not-quite the same — `ECS_IS_PAIR` and `ecs_id_is_pair`
//! are different predicates — and giving one of them the other's name is worse than not
//! binding it at all.
//!
//! ## Pointers
//!
//! C says `T*` and means one of five things. Which one is a judgment call, and the ABI
//! guard cannot make it: every pointer is one machine word, so a wrong choice compares
//! equal to a right one. The rule here, applied uniformly:
//!
//!   * **Parameters of `extern fn`** — zecs is the caller, so the *strict* form is
//!     right wherever flecs asserts the argument: `world: *ecs_world_t`, not `?*`. That
//!     turns "forgot to check for null" into a compile error at the call site.
//!   * **Parameters of a callback typedef** — flecs is the caller, so the *permissive*
//!     form is right: `?*anyopaque`, `?*const ecs_type_info_t`. A parameter declared
//!     non-optional that flecs passes null for is undefined behaviour in Zig, and no
//!     test will find it reliably.
//!   * **Return values** — permissive unless flecs documents otherwise. `ecs_query_init`
//!     returns `?*ecs_query_t`, because returning null on failure is how it reports one.
//!   * **Arrays** — `[*]T` when the count travels separately, which is most of flecs's
//!     out-parameters. Never `*T` for something indexable.
//!   * **Strings** — `[*:0]const u8` going in, `?[*:0]u8` coming out. An out-string from
//!     flecs is heap memory the caller frees with `ecs_os_free`; the mutable, optional
//!     spelling is the reminder.
//!
//! Anything flecs exposes that is not declared here is still reachable: link the
//! artifact this package builds and `@cImport` `flecs.h` directly, or declare the one
//! `extern fn` you need. Nothing in the design requires going through this file.

const std = @import("std");
const options = @import("zecs_options");

/// Whether flecs was compiled with `FLECS_DEBUG`. `FLECS_SANITIZE` implies it, which is
/// why this is not a straight equality.
///
/// Private on purpose: it is not a flecs symbol, and everything public in this file is
/// paired with a header declaration by the ABI guard.
const flecs_debug = options.debug_checks == .debug or options.debug_checks == .sanitize;
/// Whether flecs was compiled with `FLECS_SANITIZE`.
const flecs_sanitize = options.debug_checks == .sanitize;

//=============================================================================
// Configuration
//
// Constants that size public structs. Each one is a build option, so the value here
// and the value the C was compiled with come from the same place.
//=============================================================================

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

//=============================================================================
// Scalars, containers and allocators
//
// flecs keeps some of these types incomplete in the header, so there is no layout to
// mirror and a consumer can only ever hold a pointer. Anything flecs does define stays a
// struct here, even when it looks internal: declaring a defined type opaque is drift like
// any other, and the guard says so.
//
// The rest is flecs's own vectors, maps, sparse sets and allocators. They are exported
// because the macro API and the meta cursor hand them out — not because a Zig consumer should reach
// for them, since Zig has slices, `ArrayList` and `AutoHashMap` and they are better here.
//=============================================================================

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

//=============================================================================
// OS API
//
// The abstraction flecs allocates, threads, logs and sleeps through. `zecs.setAllocator`
// replaces four of these callbacks; the rest are here so a host can replace the others.
//=============================================================================

pub const ecs_time_t = extern struct {
    sec: u32 = 0,
    nanosec: u32 = 0,
};

/// Allocation counters maintained by flecs's own OS API implementation. They stop
/// moving once those callbacks are replaced, which is precisely what makes them useful
/// as evidence that flecs has already allocated through someone else's allocator.
pub extern var ecs_os_api_malloc_count: i64;
pub extern var ecs_os_api_realloc_count: i64;
pub extern var ecs_os_api_calloc_count: i64;
pub extern var ecs_os_api_free_count: i64;

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

pub const ecs_os_api_task_new_t = ?*const fn (callback: ecs_os_thread_callback_t, param: ?*anyopaque) callconv(.c) ecs_os_thread_t;

pub const ecs_os_api_task_join_t = ?*const fn (thread: ecs_os_thread_t) callconv(.c) ?*anyopaque;

pub const ecs_os_api_mutex_unlock_t = ?*const fn (mutex: ecs_os_mutex_t) callconv(.c) void;

pub const ecs_os_api_enable_high_timer_resolution_t = ?*const fn (enable: bool) callconv(.c) void;

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

pub extern fn ecs_os_init() void;
pub extern fn ecs_os_fini() void;
pub extern fn ecs_os_set_api(os_api: *const ecs_os_api_t) void;
pub extern fn ecs_os_get_api() ecs_os_api_t;
pub extern fn ecs_os_set_api_defaults() void;
pub extern fn ecs_os_has_heap() bool;
pub extern fn ecs_os_has_threading() bool;
pub extern fn ecs_os_has_task_support() bool;
pub extern fn ecs_os_has_time() bool;
pub extern fn ecs_os_has_logging() bool;
pub extern fn ecs_os_has_dl() bool;
pub extern fn ecs_os_has_modules() bool;

/// Log at debug level.
pub extern fn ecs_os_dbg(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Log at trace level.
pub extern fn ecs_os_trace(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Log at warning level.
pub extern fn ecs_os_warn(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Log at error level.
pub extern fn ecs_os_err(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Log at fatal level.
pub extern fn ecs_os_fatal(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Convert errno to a string. Static storage owned by the C library, not a copy.
pub extern fn ecs_os_strerror(err: c_int) [*:0]const u8;

/// Free whatever `str` points at and put a fresh copy of `value` there. `str` is one
/// string variable, not an array.
pub extern fn ecs_os_strset(str: *?[*:0]u8, value: ?[*:0]const u8) void;

/// Push a performance trace region.
pub extern fn ecs_os_perf_trace_push_(file: ?[*:0]const u8, line: usize, name: ?[*:0]const u8) void;

/// Pop a performance trace region.
pub extern fn ecs_os_perf_trace_pop_(file: ?[*:0]const u8, line: usize, name: ?[*:0]const u8) void;

/// Sleep with floating-point time.
pub extern fn ecs_sleepf(t: f64) void;

/// Seconds elapsed since `start`, which is then overwritten with the current time. Pass
/// a zeroed value to get the seconds since the epoch instead.
pub extern fn ecs_time_measure(start: *ecs_time_t) f64;

/// Calculate the difference between two timestamps.
pub extern fn ecs_time_sub(t1: ecs_time_t, t2: ecs_time_t) ecs_time_t;

/// Convert a time value to a double.
pub extern fn ecs_time_to_double(t: ecs_time_t) f64;

/// Return newly allocated memory that contains a copy of src.
pub extern fn ecs_os_memdup(src: ?*const anyopaque, size: ecs_size_t) ?*anyopaque;

//=============================================================================
// API types
//
// The types the query, iterator and descriptor APIs are written in terms of.
//
// The four members of `ecs_iter_t`'s private union are mirrored rather than replaced by an
// opaque blob: a blob would have to guess a size, and guessing is exactly what the ABI
// guard exists to make unnecessary. Pointers into flecs's internals are `?*anyopaque`,
// since their targets are private and this side never dereferences them.
//=============================================================================

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
/// addon, which is why the ABI guard treats it as one.
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

//=============================================================================
// Miscellaneous types
//=============================================================================

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

//=============================================================================
// Built-in component types
//
// The components flecs registers in its own world: names, docs, units, reflection.
// Each one has an `ecs_id(T)` global further down.
//=============================================================================

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

//=============================================================================
// API constants
//
// Id flags and the built-in tags. The flags are compile-time constants; the tags are
// variables in the library, read through externs rather than duplicated as literals — a
// duplicated literal would be a second place for a flecs upgrade to invalidate. They are
// zero until a world exists.
//=============================================================================

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

//=============================================================================
// World
//=============================================================================

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

//=============================================================================
// Entities
//=============================================================================

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

pub extern fn ecs_entity_init(world: *ecs_world_t, desc: *const ecs_entity_desc_t) ecs_entity_t;
pub extern fn ecs_component_init(world: *ecs_world_t, desc: *const ecs_component_desc_t) ecs_entity_t;

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
pub extern fn ecs_set_id(world: *ecs_world_t, entity: ecs_entity_t, id: ecs_id_t, size: usize, ptr: ?*const anyopaque) void;
pub extern fn ecs_get_id(world: *const ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) ?*const anyopaque;
pub extern fn ecs_get_mut_id(world: *const ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) ?*anyopaque;
pub extern fn ecs_ensure_id(world: *ecs_world_t, entity: ecs_entity_t, id: ecs_id_t, size: usize) ?*anyopaque;
pub extern fn ecs_modified_id(world: *ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) void;
pub extern fn ecs_has_id(world: *const ecs_world_t, entity: ecs_entity_t, id: ecs_id_t) bool;
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
/// with this name and returns it, which is why this returns an entity at all.
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

//=============================================================================
// Components
//=============================================================================

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

//=============================================================================
// Ids
//=============================================================================

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

/// Render an id: `Position`, `(ChildOf, parent)`, or either with a `FLAG|` in front. The
/// `PAIR` flag is left implicit. Free the result with `ecs_os_free`.
pub extern fn ecs_id_str(world: *const ecs_world_t, component: ecs_id_t) ?[*:0]u8;

/// Write a component string to a buffer. Same as ecs_id_str(), but writes the result to
/// ecs_strbuf_t.
pub extern fn ecs_id_str_buf(world: *const ecs_world_t, component: ecs_id_t, buf: *ecs_strbuf_t) void;

/// The reverse of `ecs_id_str`. Returns 0 if the string does not parse. Needs the query
/// DSL addon — flecs's own doc names the script addon here, but the implementation is
/// guarded on `FLECS_QUERY_DSL`, which script does not imply.
pub extern fn ecs_id_from_str(world: *const ecs_world_t, expr: [*:0]const u8) ecs_id_t;

//=============================================================================
// Queries
//=============================================================================

pub const ecs_query_op_ctx_t = opaque {};

pub const ecs_query_op_t = opaque {};

pub const ecs_query_var_t = opaque {};

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

/// Create a query. Null when the descriptor is invalid. If `desc.entity` names an
/// existing entity, that entity must not already hold a query; `ecs_query_update`
/// replaces one.
pub extern fn ecs_query_init(world: *ecs_world_t, desc: *const ecs_query_desc_t) ?*ecs_query_t;
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

//=============================================================================
// Observers
//=============================================================================

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

//=============================================================================
// Iterators
//=============================================================================

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

//=============================================================================
// Tables
//=============================================================================

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

//=============================================================================
// Values
//=============================================================================

/// Construct a value in existing storage, which must be large enough for the type.
/// Nonzero when `type` is not a type. The `_w_type_info` variants of these operations
/// take the type info directly and skip the lookup.
pub extern fn ecs_value_init(world: *const ecs_world_t, @"type": ecs_entity_t, ptr: *anyopaque) c_int;

pub extern fn ecs_value_init_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, ptr: *anyopaque) c_int;

/// Allocate storage and construct a value in it. Null on failure. Release it with
/// `ecs_value_free`, which is the only thing that frees this allocation correctly.
pub extern fn ecs_value_new(world: *ecs_world_t, @"type": ecs_entity_t) ?*anyopaque;

pub extern fn ecs_value_new_w_type_info(world: *ecs_world_t, ti: *const ecs_type_info_t) ?*anyopaque;

pub extern fn ecs_value_fini_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, ptr: *anyopaque) c_int;

/// Destruct a value, leaving its storage alone.
pub extern fn ecs_value_fini(world: *const ecs_world_t, @"type": ecs_entity_t, ptr: *anyopaque) c_int;

/// Destruct a value and release the storage `ecs_value_new` allocated for it.
pub extern fn ecs_value_free(world: *ecs_world_t, @"type": ecs_entity_t, ptr: *anyopaque) c_int;

pub extern fn ecs_value_copy_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, dst: *anyopaque, src: *const anyopaque) c_int;

/// Copy a value into constructed storage.
pub extern fn ecs_value_copy(world: *const ecs_world_t, @"type": ecs_entity_t, dst: *anyopaque, src: *const anyopaque) c_int;

pub extern fn ecs_value_move_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, dst: *anyopaque, src: *anyopaque) c_int;

/// Move a value into constructed storage, leaving the source constructed but empty.
pub extern fn ecs_value_move(world: *const ecs_world_t, @"type": ecs_entity_t, dst: *anyopaque, src: *anyopaque) c_int;

pub extern fn ecs_value_move_ctor_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, dst: *anyopaque, src: *anyopaque) c_int;

/// Move a value into unconstructed storage.
pub extern fn ecs_value_move_ctor(world: *const ecs_world_t, @"type": ecs_entity_t, dst: *anyopaque, src: *anyopaque) c_int;

//=============================================================================
// Macros rewritten as functions
//
// A macro has no symbol to link against, so the arithmetic ones are written out here.
// They keep flecs's own names — `ECS_PAIR_FIRST`, not a Zig spelling of it — because a
// C example has to apply unchanged, and because flecs has more than one name for things
// that are nearly-but-not-quite the same: `ECS_IS_PAIR` and `ecs_id_is_pair` are
// different predicates. `abi_check.zig` calls both sides on the same inputs, which is
// the only way to compare a function to a macro.
//=============================================================================

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

//=============================================================================
// Log
//=============================================================================

/// `va_list`, for the log entry points that take one.
pub const va_list = std.builtin.VaList;

/// Log that an operation is deprecated. Compiled away to nothing when the log addon is
/// off, which is why the ABI guard treats this name specially.
pub extern fn ecs_deprecated_(file: ?[*:0]const u8, line: i32, msg: ?[*:0]const u8) void;

/// Description for one of the `ECS_*` error codes. Static storage; do not free it.
pub extern fn ecs_strerror(error_code: i32) ?[*:0]const u8;

/// Indent subsequent log output by one level, making nested work legible. Pair it with
/// `ecs_log_pop_`.
pub extern fn ecs_log_push_(level: i32) void;

/// Undo one `ecs_log_push_`.
pub extern fn ecs_log_pop_(level: i32) void;

/// Whether a message at this level would be logged, for skipping the work of building
/// one that would be thrown away.
pub extern fn ecs_should_log(level: i32) bool;

/// Print at the provided log level.
pub extern fn ecs_print_(level: i32, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, ...) void;

/// Print at the provided log level (va_list).
pub extern fn ecs_printv_(level: c_int, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, args: va_list) void;

/// Log at the provided level.
pub extern fn ecs_log_(level: i32, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, ...) void;

/// Log at the provided level (va_list).
pub extern fn ecs_logv_(level: c_int, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, args: va_list) void;

/// Abort with error code.
pub extern fn ecs_abort_(error_code: i32, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, ...) void;

/// Log an assertion failure.
pub extern fn ecs_assert_log_(error_code: i32, condition_str: ?[*:0]const u8, file: ?[*:0]const u8, line: i32, fmt: ?[*:0]const u8, ...) void;

/// Log a parser error.
pub extern fn ecs_parser_error_(name: ?[*:0]const u8, expr: ?[*:0]const u8, column: i64, fmt: ?[*:0]const u8, ...) void;

/// Log a parser error (va_list).
pub extern fn ecs_parser_errorv_(name: ?[*:0]const u8, expr: ?[*:0]const u8, column: i64, fmt: ?[*:0]const u8, args: va_list) void;

/// Log a parser warning.
pub extern fn ecs_parser_warning_(name: ?[*:0]const u8, expr: ?[*:0]const u8, column: i64, fmt: ?[*:0]const u8, ...) void;

/// Log a parser warning (va_list).
pub extern fn ecs_parser_warningv_(name: ?[*:0]const u8, expr: ?[*:0]const u8, column: i64, fmt: ?[*:0]const u8, args: va_list) void;

/// Set the log level and return the previous one. -1 silences warnings as well as
/// traces, -2 silences errors too.
///
/// Level 0 prints, among other things, the list of addons the library was actually
/// compiled with — which is the authoritative answer to that question, since addons
/// enable their own dependencies.
pub extern fn ecs_log_set_level(level: c_int) c_int;

/// Turn ANSI colors in log output on or off, returning the previous setting. They are
/// on by default.
pub extern fn ecs_log_enable_colors(enabled: bool) bool;

pub extern fn ecs_log_get_level() c_int;

/// Turn timestamps in log output on or off, returning the previous setting. Off by
/// default, because reading the clock on every log line is not free.
pub extern fn ecs_log_enable_timestamp(enabled: bool) bool;

/// Turn the "seconds since the last log line" prefix on or off, returning the previous
/// setting. Off by default, and costs a clock read per line like timestamps do.
pub extern fn ecs_log_enable_timedelta(enabled: bool) bool;

/// The last logged error code, 0 if none was logged since the last call. Reading it
/// resets it.
pub extern fn ecs_log_last_error() c_int;

/// Start capturing log output instead of writing it out. `capture_try` also captures
/// messages from `ecs_log_try` blocks.
pub extern fn ecs_log_start_capture(capture_try: bool) void;

/// Stop capturing and return what was captured, or null if nothing was. Free the result
/// with `ecs_os_free`.
pub extern fn ecs_log_stop_capture() ?[*:0]u8;

//=============================================================================
// App
//=============================================================================

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

pub const ecs_app_run_action_t = ?*const fn (world: *ecs_world_t, desc: *ecs_app_desc_t) callconv(.c) c_int;

pub const ecs_app_frame_action_t = ?*const fn (world: *ecs_world_t, desc: *const ecs_app_desc_t) callconv(.c) c_int;

/// Run the application's main loop, then destroy the world. Calls the run action, which
/// by default calls the frame action until it returns nonzero. `ecs_quit` is what ends
/// it. The world is gone when this returns, so nothing that points into it survives.
pub extern fn ecs_app_run(world: *ecs_world_t, desc: *ecs_app_desc_t) c_int;

/// Run a single frame, the default frame action. Calls `ecs_progress` unless a custom
/// frame action was set, and returns what it returned.
pub extern fn ecs_app_run_frame(world: *ecs_world_t, desc: *const ecs_app_desc_t) c_int;

/// Replace the loop `ecs_app_run` runs. Process-wide, not per world.
pub extern fn ecs_app_set_run_action(callback: ecs_app_run_action_t) c_int;

/// Replace what `ecs_app_run_frame` does. Process-wide, not per world.
pub extern fn ecs_app_set_frame_action(callback: ecs_app_frame_action_t) c_int;

//=============================================================================
// HTTP
//=============================================================================

/// HTTP server.
pub const ecs_http_server_t = opaque {};

pub extern var ecs_http_request_received_count: i64;

pub extern var ecs_http_request_invalid_count: i64;

pub extern var ecs_http_request_handled_ok_count: i64;

pub extern var ecs_http_request_handled_error_count: i64;

pub extern var ecs_http_request_not_handled_count: i64;

pub extern var ecs_http_request_preflight_count: i64;

pub extern var ecs_http_send_ok_count: i64;

pub extern var ecs_http_send_error_count: i64;

pub extern var ecs_http_busy_count: i64;

pub const ecs_http_reply_action_t = ?*const fn (request: ?*const ecs_http_request_t, reply: ?*ecs_http_reply_t, ctx: ?*anyopaque) callconv(.c) bool;

/// Create a server. It is not listening yet; `ecs_http_server_start` does that. Null if
/// creation failed.
pub extern fn ecs_http_server_init(desc: *const ecs_http_server_desc_t) ?*ecs_http_server_t;

/// Destroy a server, stopping it first if it is still running.
pub extern fn ecs_http_server_fini(server: *ecs_http_server_t) void;

/// Start accepting requests. Needs an OS API with threading; nonzero if it could not
/// start.
pub extern fn ecs_http_server_start(server: *ecs_http_server_t) c_int;

/// Run the reply callback for each request received since the last call. No new requests
/// are enqueued while this runs, so the callback sees a stable set.
pub extern fn ecs_http_server_dequeue(server: *ecs_http_server_t, delta_time: ecs_ftime_t) void;

/// Stop accepting requests.
pub extern fn ecs_http_server_stop(server: *ecs_http_server_t) void;

/// Feed a request to the server directly, without a socket. `req` is a raw HTTP request
/// of `len` bytes — `GET /entity/flecs/core/World?label=true HTTP/1.1` and so on — and
/// need not be NUL-terminated unless `len` is 0, which asks flecs to measure it.
pub extern fn ecs_http_server_http_request(srv: *ecs_http_server_t, req: [*]const u8, len: ecs_size_t, reply_out: *ecs_http_reply_t) c_int;

/// Same as `ecs_http_server_http_request`, assembling the request line for you. `body`
/// is optional.
pub extern fn ecs_http_server_request(srv: *ecs_http_server_t, method: [*:0]const u8, req: [*:0]const u8, body: ?[*:0]const u8, reply_out: *ecs_http_reply_t) c_int;

/// The context from `ecs_http_server_desc_t.ctx`.
pub extern fn ecs_http_server_ctx(srv: *ecs_http_server_t) ?*anyopaque;

/// Find a header in a request by name. Null if the request has no such header. The
/// string belongs to the request and dies with it.
pub extern fn ecs_http_get_header(req: *const ecs_http_request_t, name: [*:0]const u8) ?[*:0]const u8;

/// Find a URL query parameter in a request by name, already percent-decoded. Null if
/// the request has no such parameter. The string belongs to the request.
pub extern fn ecs_http_get_param(req: *const ecs_http_request_t, name: [*:0]const u8) ?[*:0]const u8;

//=============================================================================
// REST
//=============================================================================

/// Create an HTTP server serving the REST API, for an application that wants to drive
/// it itself rather than through the `EcsRest` component and the flecs systems behind
/// it. Null if the server could not be created.
pub extern fn ecs_rest_server_init(world: *ecs_world_t, desc: *const ecs_http_server_desc_t) ?*ecs_http_server_t;

/// Destroy a server created with `ecs_rest_server_init`. Not interchangeable with
/// `ecs_http_server_fini`, which leaks the REST context this one frees.
pub extern fn ecs_rest_server_fini(srv: *ecs_http_server_t) void;

/// Import the REST module, the equivalent of `ECS_IMPORT(world, FlecsRest)` in C.
pub extern fn FlecsRestImport(world: *ecs_world_t) void;

//=============================================================================
// Timer
//=============================================================================

/// One-shot and interval timer component.
pub const EcsTimer = extern struct {
    timeout: ecs_ftime_t = 0,
    time: ecs_ftime_t = 0,
    /// Correction carried over when a frame overshoots the timeout.
    overshoot: ecs_ftime_t = 0,
    fired_count: i32 = 0,
    active: bool = false,
    single_shot: bool = false,
};

/// Rate filter component: ticks once every `rate` ticks of `src`.
pub const EcsRateFilter = extern struct {
    src: ecs_entity_t = 0,
    rate: i32 = 0,
    tick_count: i32 = 0,
    time_elapsed: ecs_ftime_t = 0,
};

/// Fire the entity once, `timeout` seconds from now, and make it a tick source. An
/// existing timer on the entity is reset. Time is advanced by `delta_time` each frame,
/// so this is synchronous with the main loop. When the entity is a system, the system
/// runs on the tick; otherwise read `EcsTickSource.tick`. Start and stop it with
/// `ecs_start_timer` and `ecs_stop_timer`.
pub extern fn ecs_set_timeout(world: *ecs_world_t, tick_source: ecs_entity_t, timeout: ecs_ftime_t) ecs_entity_t;

/// The timeout set by `ecs_set_timeout`. 0 when the entity has no timer — which includes
/// after the timeout fired, because that removes the `EcsTimer` component.
pub extern fn ecs_get_timeout(world: *const ecs_world_t, tick_source: ecs_entity_t) ecs_ftime_t;

/// Fire the entity every `interval` seconds and make it a tick source, otherwise like
/// `ecs_set_timeout`. An existing timer on the entity is reset.
pub extern fn ecs_set_interval(world: *ecs_world_t, tick_source: ecs_entity_t, interval: ecs_ftime_t) ecs_entity_t;

/// The interval set by `ecs_set_interval`. 0 when the entity is not a timer.
pub extern fn ecs_get_interval(world: *const ecs_world_t, tick_source: ecs_entity_t) ecs_ftime_t;

/// Reset a timer to 0 and start it.
pub extern fn ecs_start_timer(world: *ecs_world_t, tick_source: ecs_entity_t) void;

/// Stop a timer from firing, keeping its current time value.
pub extern fn ecs_stop_timer(world: *ecs_world_t, tick_source: ecs_entity_t) void;

/// Reset a timer's time value to 0 without stopping it.
pub extern fn ecs_reset_timer(world: *ecs_world_t, tick_source: ecs_entity_t) void;

/// Start new timers at a random point in their period, so that timers sharing an
/// interval do not all land on the same frame.
pub extern fn ecs_randomize_timers(world: *ecs_world_t) void;

/// Make the entity tick once every `rate` ticks of `source`, and a tick source itself,
/// so rate filters chain. With `source` 0 the frame tick is used, which counts calls to
/// `ecs_progress`. Unlike two interval timers, whose ratio drifts with floating-point
/// rounding, a rate filter ticks at an exact multiple of its source.
pub extern fn ecs_set_rate(world: *ecs_world_t, tick_source: ecs_entity_t, rate: i32, source: ecs_entity_t) ecs_entity_t;

/// Drive a system from a shared tick source. Two systems given the same interval or rate
/// can drift apart — disabling one is enough to do it — while two systems sharing a tick
/// source are guaranteed to run on the same frame.
pub extern fn ecs_set_tick_source(world: *ecs_world_t, system: ecs_entity_t, tick_source: ecs_entity_t) void;

/// Import the timer module, the equivalent of `ECS_IMPORT(world, FlecsTimer)` in C.
pub extern fn FlecsTimerImport(world: *ecs_world_t) void;

//=============================================================================
// Pipeline
//=============================================================================

pub const ecs_pipeline_desc_t = extern struct {
    entity: ecs_entity_t = 0,
    query: ecs_query_desc_t = .{},
};

/// Create a custom pipeline. 0 if the descriptor is invalid. If `desc.entity` names an
/// existing entity it must not already hold a pipeline; `ecs_pipeline_update` replaces
/// one.
pub extern fn ecs_pipeline_init(world: *ecs_world_t, desc: *const ecs_pipeline_desc_t) ecs_entity_t;

/// Replace the pipeline held by an entity, building a new one from the descriptor.
pub extern fn ecs_pipeline_update(world: *ecs_world_t, pipeline: ecs_entity_t, desc: *const ecs_pipeline_desc_t) ecs_entity_t;

/// Set the pipeline `ecs_progress` runs.
pub extern fn ecs_set_pipeline(world: *ecs_world_t, pipeline: ecs_entity_t) void;

pub extern fn ecs_get_pipeline(world: *const ecs_world_t) ecs_entity_t;

/// Scale simulation speed by a multiplier, which `ecs_progress` applies to `delta_time`.
pub extern fn ecs_set_time_scale(world: *ecs_world_t, scale: ecs_ftime_t) void;

/// Reset the clock that tracks total simulation time.
pub extern fn ecs_reset_clock(world: *ecs_world_t) void;

/// Run every system in a pipeline. Callable from several threads, but only while staging
/// is off: the pipeline owns staging and the synchronization between threads.
pub extern fn ecs_run_pipeline(world: *ecs_world_t, pipeline: ecs_entity_t, delta_time: ecs_ftime_t) void;

/// Whether the world was asked for task threads rather than long-lived worker threads.
pub extern fn ecs_using_task_threads(world: *ecs_world_t) bool;

/// Import the pipeline module, the equivalent of `ECS_IMPORT(world, FlecsPipeline)` in C.
pub extern fn FlecsPipelineImport(world: *ecs_world_t) void;

//=============================================================================
// System
//=============================================================================

/// Tick source component, added by the timer operations. `tick` is true on the frames
/// the source fires; `time_elapsed` is the time since the previous tick.
pub const EcsTickSource = extern struct {
    tick: bool = false,
    time_elapsed: ecs_ftime_t = 0,
};

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

pub extern fn ecs_system_init(world: *ecs_world_t, desc: *const ecs_system_desc_t) ecs_entity_t;
pub extern fn ecs_run(world: *ecs_world_t, system: ecs_entity_t, delta_time: ecs_ftime_t, param: ?*anyopaque) ecs_entity_t;
pub extern fn ecs_observer_init(world: *ecs_world_t, desc: *const ecs_observer_desc_t) ecs_entity_t;

/// Reconfigure a system created with `ecs_system_init`. Only fields of `desc` set to a
/// non-default value are applied; the rest keep their current value.
pub extern fn ecs_system_update(world: *ecs_world_t, system: ecs_entity_t, desc: *const ecs_system_desc_t) ecs_entity_t;

pub const ecs_system_t = extern struct {
    hdr: ecs_header_t = .{},
    run: ecs_run_action_t = null,
    action: ecs_iter_action_t = null,
    query: ?*ecs_query_t = null,
    group_id: u64 = 0,
    group_id_set: bool = false,
    tick_source: ecs_entity_t = 0,
    multi_threaded: bool = false,
    immediate: bool = false,
    name: ?[*:0]const u8 = null,
    ctx: ?*anyopaque = null,
    callback_ctx: ?*anyopaque = null,
    run_ctx: ?*anyopaque = null,
    ctx_free: ecs_ctx_free_t = null,
    callback_ctx_free: ecs_ctx_free_t = null,
    run_ctx_free: ecs_ctx_free_t = null,
    time_spent: ecs_ftime_t = 0,
    time_passed: ecs_ftime_t = 0,
    last_frame: i64 = 0,
    dtor: flecs_poly_dtor_t = null,
};

/// Get an entity's system, for reading its query and context. Null when the entity is
/// not a system.
pub extern fn ecs_system_get(world: *const ecs_world_t, system: ecs_entity_t) ?*const ecs_system_t;

/// Restrict a system built on a grouped query to one group. Applies to manual runs and
/// to pipeline execution alike.
pub extern fn ecs_system_set_group(world: *ecs_world_t, system: ecs_entity_t, group_id: u64) void;

/// Same as `ecs_run`, over this worker's share of the matched entities.
pub extern fn ecs_run_worker(world: *ecs_world_t, system: ecs_entity_t, stage_current: i32, stage_count: i32, delta_time: ecs_ftime_t, param: ?*anyopaque) ecs_entity_t;

/// Import the system module, the equivalent of `ECS_IMPORT(world, FlecsSystem)` in C.
pub extern fn FlecsSystemImport(world: *ecs_world_t) void;

//=============================================================================
// Stats
//=============================================================================

/// A value sampled over a window. flecs's `ECS_STAT_WINDOW` is 60, and the arrays are a
/// ring buffer indexed by the owning struct's `t`.
pub const ecs_gauge_t = extern struct {
    avg: [60]ecs_float_t = @splat(0),
    min: [60]ecs_float_t = @splat(0),
    max: [60]ecs_float_t = @splat(0),
};

/// A monotonically increasing count over the same window as `ecs_gauge_t`, which keeps
/// the per-sample deltas in `rate` alongside the running totals.
pub const ecs_counter_t = extern struct {
    rate: ecs_gauge_t = .{},
    value: [60]f64 = @splat(0),
};

/// Make all metrics the same size, so we can iterate over fields.
pub const ecs_metric_t = extern union {
    gauge: ecs_gauge_t,
    counter: ecs_counter_t,
};

/// World statistics. `first_` and `last_` bracket the metrics so flecs can walk them as
/// an array; do not write to either. `t` is the ring buffer cursor the metric arrays are
/// indexed by.
pub const ecs_world_stats_t = extern struct {
    first_: i64 = 0,
    entities: extern struct {
        count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        not_alive_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    } = .{},
    components: extern struct {
        tag_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        component_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        pair_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        type_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        create_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        delete_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    } = .{},
    tables: extern struct {
        count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        empty_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        create_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        delete_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    } = .{},
    queries: extern struct {
        query_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        observer_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        system_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    } = .{},
    commands: extern struct {
        add_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        remove_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        delete_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        clear_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        set_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        ensure_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        modified_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        other_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        discard_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        batched_entity_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        batched_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    } = .{},
    frame: extern struct {
        frame_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        merge_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        rematch_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        pipeline_build_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        systems_ran: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        observers_ran: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        event_emit_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    } = .{},
    performance: extern struct {
        world_time_raw: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        world_time: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        frame_time: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        system_time: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        emit_time: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        merge_time: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        rematch_time: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        fps: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        delta_time: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    } = .{},
    memory: extern struct {
        alloc_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        realloc_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        free_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        outstanding_alloc_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        block_alloc_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        block_free_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        block_outstanding_alloc_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        stack_alloc_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        stack_free_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        stack_outstanding_alloc_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    } = .{},
    http: extern struct {
        request_received_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        request_invalid_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        request_handled_ok_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        request_handled_error_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        request_not_handled_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        request_preflight_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        send_ok_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        send_error_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
        busy_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    } = .{},
    last_: i64 = 0,
    t: i32 = 0,
};

pub const ecs_query_stats_t = extern struct {
    first_: i64 = 0,
    result_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    matched_table_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    matched_entity_count: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    last_: i64 = 0,
    t: i32 = 0,
};

pub const ecs_system_stats_t = extern struct {
    first_: i64 = 0,
    time_spent: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    last_: i64 = 0,
    task: bool = false,
    query: ecs_query_stats_t = .{},
};

pub const ecs_sync_stats_t = extern struct {
    first_: i64 = 0,
    time_spent: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    commands_enqueued: ecs_metric_t = std.mem.zeroes(ecs_metric_t),
    last_: i64 = 0,
    system_count: i32 = 0,
    multi_threaded: bool = false,
    immediate: bool = false,
};

/// Statistics for every system in a pipeline. Release it with `ecs_pipeline_stats_fini`,
/// which frees the two vectors.
pub const ecs_pipeline_stats_t = extern struct {
    canary_: i8 = 0,
    /// `ecs_vec_t` of `ecs_entity_t`: the pipeline's systems in execution order, with a
    /// 0 standing for a merge.
    systems: ecs_vec_t = .{},
    /// `ecs_vec_t` of `ecs_sync_stats_t`.
    sync_points: ecs_vec_t = .{},
    t: i32 = 0,
    system_count: i32 = 0,
    active_system_count: i32 = 0,
    rebuild_count: i32 = 0,
};

/// Sample world statistics into the next slot of `stats`, advancing its cursor.
pub extern fn ecs_world_stats_get(world: *const ecs_world_t, stats: *ecs_world_stats_t) void;

/// Fold every sample in `src`'s window into one sample appended to `dst`. This is how a
/// second of samples becomes one minute-resolution sample.
pub extern fn ecs_world_stats_reduce(dst: *ecs_world_stats_t, src: *const ecs_world_stats_t) void;

/// Fold the last sample of `stats` into the one before it and restore `old` as the new
/// last sample, rewinding the cursor by one. `count` is how many samples the previous
/// one already averages, not an element count: `old` is a single struct.
pub extern fn ecs_world_stats_reduce_last(stats: *ecs_world_stats_t, old: *const ecs_world_stats_t, count: i32) void;

/// Append a copy of the last sample, so a window with no new data still advances.
pub extern fn ecs_world_stats_repeat_last(stats: *ecs_world_stats_t) void;

/// Copy `src`'s last sample over `dst`'s, leaving `dst`'s cursor alone.
pub extern fn ecs_world_stats_copy_last(dst: *ecs_world_stats_t, src: *const ecs_world_stats_t) void;

/// Log world statistics at the current log level.
pub extern fn ecs_world_stats_log(world: *const ecs_world_t, stats: *const ecs_world_stats_t) void;

/// Sample a query's statistics. The rest of the `ecs_query_cache_stats_*` family works
/// like the `ecs_world_stats_*` one.
pub extern fn ecs_query_stats_get(world: *const ecs_world_t, query: *const ecs_query_t, stats: *ecs_query_stats_t) void;

pub extern fn ecs_query_cache_stats_reduce(dst: *ecs_query_stats_t, src: *const ecs_query_stats_t) void;

pub extern fn ecs_query_cache_stats_reduce_last(stats: *ecs_query_stats_t, old: *const ecs_query_stats_t, count: i32) void;

pub extern fn ecs_query_cache_stats_repeat_last(stats: *ecs_query_stats_t) void;

pub extern fn ecs_query_cache_stats_copy_last(dst: *ecs_query_stats_t, src: *const ecs_query_stats_t) void;

/// Sample a system's statistics. False when the entity is not a system, in which case
/// `stats` is untouched.
pub extern fn ecs_system_stats_get(world: *const ecs_world_t, system: ecs_entity_t, stats: *ecs_system_stats_t) bool;

pub extern fn ecs_system_stats_reduce(dst: *ecs_system_stats_t, src: *const ecs_system_stats_t) void;

pub extern fn ecs_system_stats_reduce_last(stats: *ecs_system_stats_t, old: *const ecs_system_stats_t, count: i32) void;

pub extern fn ecs_system_stats_repeat_last(stats: *ecs_system_stats_t) void;

pub extern fn ecs_system_stats_copy_last(dst: *ecs_system_stats_t, src: *const ecs_system_stats_t) void;

/// Sample a pipeline's statistics. False when the entity is not a pipeline. The result
/// owns heap memory; release it with `ecs_pipeline_stats_fini`.
pub extern fn ecs_pipeline_stats_get(world: *ecs_world_t, pipeline: ecs_entity_t, stats: *ecs_pipeline_stats_t) bool;

/// Free the vectors inside a pipeline stats struct.
pub extern fn ecs_pipeline_stats_fini(stats: *ecs_pipeline_stats_t) void;

pub extern fn ecs_pipeline_stats_reduce(dst: *ecs_pipeline_stats_t, src: *const ecs_pipeline_stats_t) void;

pub extern fn ecs_pipeline_stats_reduce_last(stats: *ecs_pipeline_stats_t, old: *const ecs_pipeline_stats_t, count: i32) void;

pub extern fn ecs_pipeline_stats_repeat_last(stats: *ecs_pipeline_stats_t) void;

pub extern fn ecs_pipeline_stats_copy_last(dst: *ecs_pipeline_stats_t, src: *const ecs_pipeline_stats_t) void;

/// Fold `src`'s sample at index `t_src` into `dst`'s at index `t_dst`. The primitive the
/// `_reduce` operations above are built from.
pub extern fn ecs_metric_reduce(dst: *ecs_metric_t, src: *const ecs_metric_t, t_dst: i32, t_src: i32) void;

/// Fold the sample after index `t` into the one at `t`, weighting by `count`.
pub extern fn ecs_metric_reduce_last(m: *ecs_metric_t, t: i32, count: i32) void;

/// Copy one sample of a metric to another index of the same metric.
pub extern fn ecs_metric_copy(m: *ecs_metric_t, dst: i32, src: i32) void;

pub extern var EcsPeriod1s: ecs_entity_t;

pub extern var EcsPeriod1m: ecs_entity_t;

pub extern var EcsPeriod1h: ecs_entity_t;

pub extern var EcsPeriod1d: ecs_entity_t;

pub extern var EcsPeriod1w: ecs_entity_t;

/// Memory used by the entity index.
pub extern fn ecs_entity_memory_get(world: *const ecs_world_t) ecs_entities_memory_t;

/// Add one component record's memory to `result`. The `_memory_get` operations that take
/// a result out-parameter accumulate into it rather than overwrite it, which is how they
/// are summed across many records; zero it first for a single reading.
pub extern fn ecs_component_record_memory_get(cr: *const ecs_component_record_t, result: *ecs_component_index_memory_t) void;

/// Memory used by the component index, summed over every component record.
pub extern fn ecs_component_index_memory_get(world: *const ecs_world_t) ecs_component_index_memory_t;

/// Add one query's memory to `result`. Accumulates, as `ecs_component_record_memory_get`
/// does.
pub extern fn ecs_query_memory_get(query: *const ecs_query_t, result: *ecs_query_memory_t) void;

/// Memory used by every query in the world.
pub extern fn ecs_queries_memory_get(world: *const ecs_world_t) ecs_query_memory_t;

/// Add one table's component memory to `result`. Accumulates.
pub extern fn ecs_table_component_memory_get(table: *const ecs_table_t, result: *ecs_component_memory_t) void;

/// Memory used by component data across every table.
pub extern fn ecs_component_memory_get(world: *const ecs_world_t) ecs_component_memory_t;

/// Add one table's own memory to `result`, not counting component data. Accumulates.
pub extern fn ecs_table_memory_get(table: *const ecs_table_t, result: *ecs_table_memory_t) void;

/// Memory used by every table in the world.
pub extern fn ecs_tables_memory_get(world: *const ecs_world_t) ecs_table_memory_t;

/// Distribution of tables by how many entities they hold.
pub extern fn ecs_table_histogram_get(world: *const ecs_world_t) ecs_table_histogram_t;

/// Memory used by allocations that fit none of the other categories.
pub extern fn ecs_misc_memory_get(world: *const ecs_world_t) ecs_misc_memory_t;

/// Memory held by the world's allocators, including what they have reserved but not
/// handed out.
pub extern fn ecs_allocator_memory_get(world: *const ecs_world_t) ecs_allocator_memory_t;

/// Total bytes the world uses.
pub extern fn ecs_memory_get(world: *const ecs_world_t) ecs_size_t;

/// Import the stats module, the equivalent of `ECS_IMPORT(world, FlecsStats)` in C.
pub extern fn FlecsStatsImport(world: *ecs_world_t) void;

//=============================================================================
// Metrics
//=============================================================================

pub extern var EcsMetric: ecs_entity_t;

pub extern var EcsCounter: ecs_entity_t;

pub extern var EcsCounterIncrement: ecs_entity_t;

pub extern var EcsCounterId: ecs_entity_t;

pub extern var EcsGauge: ecs_entity_t;

pub extern var EcsMetricInstance: ecs_entity_t;

/// Value of a metric instance.
pub const EcsMetricValue = extern struct {
    value: f64 = 0,
};

/// The entity a metric instance was measured from.
pub const EcsMetricSource = extern struct {
    entity: ecs_entity_t = 0,
};

pub const ecs_metric_desc_t = extern struct {
    /// Validity check. Do not set.
    _canary: i32 = 0,
    entity: ecs_entity_t = 0,
    /// Member holding the measured value. Mutually exclusive with `id`, and not usable
    /// with `EcsCounterId`.
    member: ecs_entity_t = 0,
    /// Dotted member path, for nested members. Set it together with `id` and instead of
    /// `member`.
    dotmember: ?[*:0]const u8 = null,
    /// Component whose presence is measured. Mutually exclusive with `member`.
    id: ecs_id_t = 0,
    /// For an `(R, *)` id, measure each target separately rather than the pair as a
    /// whole. Needs `R` to have the `OneOf` property unless the kind is `EcsCounterId`.
    targets: bool = false,
    /// `EcsGauge`, `EcsCounter`, `EcsCounterIncrement` or `EcsCounterId`.
    kind: ecs_entity_t = 0,
    /// Only stored when the doc addon is enabled.
    brief: ?[*:0]const u8 = null,
};

/// Create a metric: an entity that samples something out of the storage — a member
/// value, how long an entity has had a component, how many entities have one — behind
/// one interface a monitor or a debugger can discover. A gauge reads the value now; the
/// three counter kinds accumulate. `EcsCounter` stores the member as-is,
/// `EcsCounterIncrement` adds `member * delta_time` each frame, and `EcsCounterId`
/// counts entities holding an id.
pub extern fn ecs_metric_init(world: *ecs_world_t, desc: *const ecs_metric_desc_t) ecs_entity_t;

/// Import the metrics module, the equivalent of `ECS_IMPORT(world, FlecsMetrics)` in C.
pub extern fn FlecsMetricsImport(world: *ecs_world_t) void;

//=============================================================================
// Alerts
//=============================================================================

pub extern var EcsAlertInfo: ecs_entity_t;

pub extern var EcsAlertWarning: ecs_entity_t;

pub extern var EcsAlertError: ecs_entity_t;

pub extern var EcsAlertCritical: ecs_entity_t;

/// The generated message of an alert instance. Owned by flecs.
pub const EcsAlertInstance = extern struct {
    message: ?[*:0]u8 = null,
};

/// Added to an entity while it has active alerts, removed once the last one clears.
/// flecs defines this type, but it holds an `ecs_map_t`, which this file keeps opaque.
pub const EcsAlertsActive = opaque {};

/// Raises an alert's severity for entities that also match `with`, so that one alert
/// covers several severities and an entity can move between them without resetting how
/// long the alert has been active.
pub const ecs_alert_severity_filter_t = extern struct {
    severity: ecs_entity_t = 0,
    with: ecs_id_t = 0,
    /// Query variable to match `with` on, written without the `$`. Null means `$this`.
    @"var": ?[*:0]const u8 = null,
    /// Resolved index of `var`. Do not set.
    _var_index: i32 = 0,
};

pub const ecs_alert_desc_t = extern struct {
    /// Validity check. Do not set.
    _canary: i32 = 0,
    entity: ecs_entity_t = 0,
    /// The query the alert watches. At least one term must use `$this`.
    query: ecs_query_desc_t = .{},
    /// Message template, interpolated by `ecs_script_string_interpolate`, so it can name
    /// query variables: `"$this has Position but not Velocity"`.
    message: ?[*:0]const u8 = null,
    /// Only stored when the doc addon is enabled.
    doc_name: ?[*:0]const u8 = null,
    /// Only stored when the doc addon is enabled.
    brief: ?[*:0]const u8 = null,
    /// `EcsAlertInfo`, `EcsAlertWarning`, `EcsAlertError` or `EcsAlertCritical`.
    /// Defaults to `EcsAlertError`.
    severity: ecs_entity_t = 0,
    severity_filters: [4]ecs_alert_severity_filter_t = @splat(.{}),
    /// How long an alert stays after it stops matching, which keeps a noisy alert from
    /// flickering. Its duration stops growing while it is inactive. 0 clears at once.
    retain_period: ecs_ftime_t = 0,
    /// Alert when this member leaves the ranges in its `EcsMemberRanges` component.
    member: ecs_entity_t = 0,
    /// Component holding `member`. Defaults to the member's parent entity.
    id: ecs_id_t = 0,
    /// Query variable to read `id` from, written without the `$`. Null means `$this`.
    @"var": ?[*:0]const u8 = null,
};

/// Create an alert: a query evaluated periodically that raises one alert instance per
/// matching entity, and clears it when the query stops matching. Instances are children
/// of the alert and carry `EcsAlertInstance` with the message, `EcsMetricSource` with
/// the entity, and `EcsMetricValue` with how long the alert has been active — the
/// metrics components, so alerts show up in whatever discovers metrics.
pub extern fn ecs_alert_init(world: *ecs_world_t, desc: *const ecs_alert_desc_t) ecs_entity_t;

/// How many alerts are active for an entity. With `alert` set, whether that one alert is
/// active; with `alert` 0, the total across all of them.
pub extern fn ecs_get_alert_count(world: *const ecs_world_t, entity: ecs_entity_t, alert: ecs_entity_t) i32;

/// The alert instance an entity has for an alert, 0 when the alert is not active for it.
pub extern fn ecs_get_alert(world: *const ecs_world_t, entity: ecs_entity_t, alert: ecs_entity_t) ecs_entity_t;

/// Import the alerts module, the equivalent of `ECS_IMPORT(world, FlecsAlerts)` in C.
pub extern fn FlecsAlertsImport(world: *ecs_world_t) void;

//=============================================================================
// JSON
//=============================================================================

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

/// Serialize one value to JSON, the same as `ecs_array_to_json` with count 0. Free the
/// result with `ecs_os_free`.
pub extern fn ecs_ptr_to_json(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque) ?[*:0]u8;

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

//=============================================================================
// Script
//=============================================================================

/// Import the script math module, the equivalent of `ECS_IMPORT(world, FlecsScriptMath)`
/// in C. Registers the math functions scripts can call.
pub extern fn FlecsScriptMathImport(world: *ecs_world_t) void;

pub extern var EcsScriptTemplate: ecs_entity_t;

pub extern var EcsScriptVectorType: ecs_entity_t;

pub const ecs_script_template_t = opaque {};

/// A script variable. `sp` is its stack pointer, for `ecs_script_vars_from_sp`.
pub const ecs_script_var_t = extern struct {
    /// Null for an anonymous variable.
    name: ?[*:0]const u8 = null,
    value: ecs_value_t = .{},
    type_info: ?*const ecs_type_info_t = null,
    sp: i32 = 0,
    is_const: bool = false,
};

/// A scope of script variables. flecs defines this type, but it holds an
/// `ecs_hashmap_t`, which this file keeps opaque.
pub const ecs_script_vars_t = opaque {};

pub const ecs_script_t = extern struct {
    world: ?*ecs_world_t = null,
    name: ?[*:0]const u8 = null,
    code: ?[*:0]const u8 = null,
};

/// Runtime for executing scripts.
pub const ecs_script_runtime_t = opaque {};

/// Added to the entity of a managed script or a template. Everything in it is owned by
/// flecs.
pub const EcsScript = extern struct {
    filename: ?[*:0]u8 = null,
    code: ?[*:0]u8 = null,
    /// Set when evaluating the script produced errors.
    @"error": ?[*:0]u8 = null,
    script: ?*ecs_script_t = null,
    /// Only set for a template script.
    template_: ?*ecs_script_template_t = null,
};

pub const ecs_function_ctx_t = extern struct {
    world: ?*ecs_world_t = null,
    function: ecs_entity_t = 0,
    ctx: ?*anyopaque = null,
};

/// A function a script can call. `argv` points at `argc` values, and the callback writes
/// through `result`, whose type is the function's declared return type.
pub const ecs_function_callback_t = ?*const fn (ctx: ?*const ecs_function_ctx_t, argc: i32, argv: ?[*]const ecs_value_t, result: ?*ecs_value_t) callconv(.c) void;

/// Same as `ecs_function_callback_t`, over `elem_count` elements at once.
pub const ecs_vector_function_callback_t = ?*const fn (ctx: ?*const ecs_function_ctx_t, argc: i32, argv: ?[*]const ecs_value_t, result: ?*ecs_value_t, elem_count: i32) callconv(.c) void;

/// One parameter of a script function.
pub const ecs_script_parameter_t = extern struct {
    name: ?[*:0]const u8 = null,
    type: ecs_entity_t = 0,
};

/// A const variable scripts can read, on the entity `ecs_const_var_init` created. The
/// value is owned by flecs.
pub const EcsScriptConstVar = extern struct {
    value: ecs_value_t = .{},
    type_info: ?*const ecs_type_info_t = null,
};

pub const ecs_script_function_t = extern struct {
    return_type: ecs_entity_t = 0,
    /// `ecs_vec_t` of `ecs_script_parameter_t`.
    params: ecs_vec_t = .{},
    callback: ecs_function_callback_t = null,
    vector_callbacks: [18]ecs_vector_function_callback_t = @splat(null),
    ctx: ?*anyopaque = null,
    binding_ctx: ?*anyopaque = null,
    binding_ctx_free: ecs_ctx_free_t = null,
};

pub const ecs_script_eval_desc_t = extern struct {
    /// Variables the script refers to.
    vars: ?*ecs_script_vars_t = null,
    /// Reusable runtime. Null makes one for the duration of the call.
    runtime: ?*ecs_script_runtime_t = null,
};

/// Captured error output from parsing or evaluating a script.
pub const ecs_script_eval_result_t = extern struct {
    /// Null when there was no error. Otherwise heap memory the caller frees with
    /// `ecs_os_free`.
    @"error": ?[*:0]u8 = null,
    /// 1-based line of the first error, 0 when not known.
    line: i32 = 0,
    /// 1-based column of the first error, 0 when not known.
    column: i32 = 0,
};

/// Parse a script into a script object, to be run with `ecs_script_eval`. Null on a
/// parse error. A script that reads outside variables needs a `desc.vars` scope
/// declaring all of them with the right types. Passing `result` turns on error capture;
/// `result.error` is then heap memory the caller frees. Both `desc` and `result` may be
/// null. `name` is used in error messages. `code` null is read as an empty script.
pub extern fn ecs_script_parse(world: *ecs_world_t, name: ?[*:0]const u8, code: ?[*:0]const u8, desc: ?*const ecs_script_eval_desc_t, result: ?*ecs_script_eval_result_t) ?*ecs_script_t;

/// Run a parsed script. The variable scope may differ from the one `ecs_script_parse`
/// saw, as long as it declares the same variables with the same types. Passing `result`
/// turns on error capture; `result.error` is then heap memory the caller frees. Both
/// `desc` and `result` may be null.
pub extern fn ecs_script_eval(script: *const ecs_script_t, desc: ?*const ecs_script_eval_desc_t, result: ?*ecs_script_eval_result_t) c_int;

/// Release a script object. Templates the script created hold a reference to it, so the
/// object outlives this call until the last of them is deleted.
pub extern fn ecs_script_free(script: *ecs_script_t) void;

/// Parse a script and instantiate its entities in one call: `ecs_script_parse`, then
/// `ecs_script_eval`, then `ecs_script_free`. `result` is optional and works as it does
/// for `ecs_script_parse`.
pub extern fn ecs_script_run(world: *ecs_world_t, name: ?[*:0]const u8, code: ?[*:0]const u8, result: ?*ecs_script_eval_result_t) c_int;

/// Same as `ecs_script_run`, reading the script from a file. The filename doubles as the
/// script name in error messages.
pub extern fn ecs_script_run_file(world: *ecs_world_t, filename: [*:0]const u8) c_int;

/// Create a script runtime, the container for whatever evaluating a script allocates.
/// `ecs_script_run` and `ecs_script_eval` make one per call when not given one, so this
/// is a way to amortize that across many evaluations. Each thread needs its own. Release
/// it with `ecs_script_runtime_free`.
pub extern fn ecs_script_runtime_new() ?*ecs_script_runtime_t;

pub extern fn ecs_script_runtime_free(runtime: *ecs_script_runtime_t) void;

/// Render a script's abstract syntax tree into a buffer, for debugging a script.
pub extern fn ecs_script_ast_to_buf(script: *ecs_script_t, buf: *ecs_strbuf_t, colors: bool) c_int;

/// Same as `ecs_script_ast_to_buf`, returning a string. Null on failure or when the
/// script has no AST. Free the result with `ecs_os_free`.
pub extern fn ecs_script_ast_to_str(script: *ecs_script_t, colors: bool) ?[*:0]u8;

pub const ecs_script_desc_t = extern struct {
    entity: ecs_entity_t = 0,
    filename: ?[*:0]const u8 = null,
    code: ?[*:0]const u8 = null,
};

/// Load a managed script: one that remembers the entities it created and keeps them in
/// step when its code is replaced, deleting the ones the new version no longer defines.
/// Experimental, in flecs's own words.
pub extern fn ecs_script_init(world: *ecs_world_t, desc: *const ecs_script_desc_t) ecs_entity_t;

/// Replace a managed script's code, reconciling the entities it created. `instance` is
/// optional and names a template instance.
pub extern fn ecs_script_update(world: *ecs_world_t, script: ecs_entity_t, instance: ecs_entity_t, code: ?[*:0]const u8) c_int;

/// Delete every entity a managed script created.
pub extern fn ecs_script_clear(world: *ecs_world_t, script: ecs_entity_t, instance: ecs_entity_t) void;

/// Create a root variable scope. Scopes nest, so the same name can mean different things
/// at different depths, with the innermost winning. A variable holding an allocated
/// value is destructed by `ecs_script_vars_pop` when it has type info with a `dtor`
/// hook. Release the root with `ecs_script_vars_fini`.
pub extern fn ecs_script_vars_init(world: *ecs_world_t) ?*ecs_script_vars_t;

/// Release a root variable scope, which must have no parent. Pops the scope on the way.
pub extern fn ecs_script_vars_fini(vars: *ecs_script_vars_t) void;

/// Push a nested variable scope, inheriting the parent's stack and allocator. Null
/// parent makes a root scope. Pair it with `ecs_script_vars_pop`.
pub extern fn ecs_script_vars_push(parent: ?*ecs_script_vars_t) ?*ecs_script_vars_t;

/// Pop a variable scope, releasing its variables, and return its parent. The scope must
/// be the top of the stack; popping any other is undefined behaviour.
pub extern fn ecs_script_vars_pop(vars: *ecs_script_vars_t) ?*ecs_script_vars_t;

/// Declare a variable in the current scope without allocating storage for it, so that it
/// can point at a value that already exists. Null `name` declares an anonymous variable,
/// reachable only by stack pointer. Null when the scope already has that name.
pub extern fn ecs_script_vars_declare(vars: *ecs_script_vars_t, name: ?[*:0]const u8) ?*ecs_script_var_t;

/// Declare a variable and allocate storage for it from the scope's stack allocator,
/// running the type's ctor. The storage dies with the scope. Null when `type` is not a
/// type or the name is taken.
pub extern fn ecs_script_vars_define_id(vars: *ecs_script_vars_t, name: ?[*:0]const u8, @"type": ecs_entity_t) ?*ecs_script_var_t;

/// Look a variable up by name, walking out to the parent scopes when the current one
/// does not have it. Null when no scope does, and when `vars` itself is null.
pub extern fn ecs_script_vars_lookup(vars: ?*const ecs_script_vars_t, name: [*:0]const u8) ?*ecs_script_var_t;

/// Look a variable up by stack pointer, faster than by name, for scopes whose variables
/// are always declared in the same order. Null when `sp` is out of range.
pub extern fn ecs_script_vars_from_sp(vars: *const ecs_script_vars_t, sp: i32) ?*ecs_script_var_t;

/// Print the variables of a scope and its parents to stdout.
pub extern fn ecs_script_vars_print(vars: *const ecs_script_vars_t) void;

/// Reserve room for `count` variables. A performance tweak only, and the scope must
/// still be empty.
pub extern fn ecs_script_vars_set_size(vars: *ecs_script_vars_t, count: i32) void;

/// Bind an iterator's current result to variables, so that expressions can read it. Does
/// not advance the iterator. Fields become variables named by index — `$1`, `$2` — and
/// query variables that hold a single entity become variables under their own names.
/// `offset` picks which element of the component arrays to bind, and must be below
/// `it.count`. The variables point into the iterator's data, so they die with it or when
/// it advances. An existing variable whose type does not match makes this fail; a
/// variable the iterator says nothing about is left alone. No reflection data is
/// required here, but using such a variable in an expression will fail.
pub extern fn ecs_script_vars_from_iter(it: *const ecs_iter_t, vars: *ecs_script_vars_t, offset: c_int) void;

pub const ecs_expr_eval_desc_t = extern struct {
    /// Script name, used in log messages only.
    name: ?[*:0]const u8 = null,
    /// The full expression, used in log messages only.
    expr: ?[*:0]const u8 = null,
    /// Variables the expression may read.
    vars: ?*const ecs_script_vars_t = null,
    /// Expected type of the result.
    type: ecs_entity_t = 0,
    /// Replaces the default identifier lookup, which is `ecs_lookup`.
    lookup_action: ?*const fn (world: ?*const ecs_world_t, value: ?[*:0]const u8, ctx: ?*anyopaque) callconv(.c) ecs_entity_t = null,
    lookup_ctx: ?*anyopaque = null,
    /// Skip constant folding: parses faster, evaluates slower.
    disable_folding: bool = false,
    /// Bind variables by stack pointer rather than by name, which is faster but requires
    /// that they are always declared in the same order.
    disable_dynamic_variable_binding: bool = false,
    /// Tolerate identifiers that do not resolve yet, for entities created between
    /// parsing and evaluation.
    allow_unresolved_identifiers: bool = false,
    /// Reusable runtime. Null makes one for the duration of the call.
    runtime: ?*ecs_script_runtime_t = null,
    /// flecs-internal.
    script_visitor: ?*anyopaque = null,
    /// flecs-internal.
    unresolved_identifier_action: ?*const fn (world: ?*const ecs_world_t, value: ?[*:0]const u8, ctx: ?*anyopaque) callconv(.c) bool = null,
};

/// Parse and evaluate an expression in one call, writing through `value`. The result is
/// cast when `value.type` differs from the expression's type. A `value.ptr` of null asks
/// flecs to allocate the storage, which the caller then releases with `ecs_value_free`.
/// Returns a pointer into `ptr` just past the last character read, or null on failure.
/// `desc` may be null.
pub extern fn ecs_expr_run(world: *ecs_world_t, ptr: [*:0]const u8, value: *ecs_value_t, desc: ?*const ecs_expr_eval_desc_t) ?[*:0]const u8;

/// Parse an expression into an object that `ecs_expr_eval` can run repeatedly. Null on a
/// parse error. `desc` may be null. Release it with `ecs_script_free`.
pub extern fn ecs_expr_parse(world: *ecs_world_t, expr: [*:0]const u8, desc: ?*const ecs_expr_eval_desc_t) ?*ecs_script_t;

/// Evaluate an expression parsed by `ecs_expr_parse`, writing through `value` as
/// `ecs_expr_run` does. `desc` may be null.
pub extern fn ecs_expr_eval(script: *const ecs_script_t, value: *ecs_value_t, desc: ?*const ecs_expr_eval_desc_t) c_int;

/// Replace the expressions embedded in a string with their values. The two forms are
/// `$variable_name` and `{expression}`, and `$`, `{` and `}` are escaped with a
/// backslash. Null on failure. Free the result with `ecs_os_free`.
pub extern fn ecs_script_string_interpolate(world: *ecs_world_t, str: [*:0]const u8, vars: ?*const ecs_script_vars_t) ?[*:0]u8;

pub const ecs_const_var_desc_t = extern struct {
    name: ?[*:0]const u8 = null,
    /// Namespace to create the variable under.
    parent: ecs_entity_t = 0,
    type: ecs_entity_t = 0,
    /// Copied into flecs's own storage, so it need not outlive the call.
    value: ?*anyopaque = null,
};

/// Create a const variable scripts can read. `desc.name`, `desc.type` and `desc.value`
/// are all required; 0 when the name is already taken under that parent.
pub extern fn ecs_const_var_init(world: *ecs_world_t, desc: *ecs_const_var_desc_t) ecs_entity_t;

/// The value of a const variable, from `ecs_const_var_init` or from `export const v: ...`
/// in a script. Owned by the variable's entity.
pub extern fn ecs_const_var_get(world: *const ecs_world_t, @"var": ecs_entity_t) ecs_value_t;

pub const ecs_vector_fn_callbacks_t = extern struct {
    i8: ecs_vector_function_callback_t = null,
    i32: ecs_vector_function_callback_t = null,
};

pub const ecs_function_desc_t = extern struct {
    name: ?[*:0]const u8 = null,
    /// Namespace to create the function under. For a method this is the type it is
    /// called on.
    parent: ecs_entity_t = 0,
    /// Zero-terminated: the first entry with a null name ends the list.
    params: [16]ecs_script_parameter_t = @splat(.{}),
    return_type: ecs_entity_t = 0,
    callback: ecs_function_callback_t = null,
    /// Needed when a parameter has type `EcsScriptVectorType`, which lets one function
    /// be called with any struct whose members share a primitive type. Indexed by
    /// `ecs_primitive_kind_t`.
    vector_callbacks: [18]ecs_vector_function_callback_t = @splat(null),
    ctx: ?*anyopaque = null,
};

/// Create a function a script can call.
pub extern fn ecs_function_init(world: *ecs_world_t, desc: *const ecs_function_desc_t) ecs_entity_t;

/// Create a method a script can call on an instance of a type. Like a function, except
/// that it lives in the scope of `desc.parent`, which is the type, and receives the
/// instance as its first argument.
pub extern fn ecs_method_init(world: *ecs_world_t, desc: *const ecs_function_desc_t) ecs_entity_t;

/// Serialize a value to a script expression, which parses back to the same value. Null
/// when the type has no reflection data. Free the result with `ecs_os_free`.
pub extern fn ecs_ptr_to_expr(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque) ?[*:0]u8;

/// Same as `ecs_ptr_to_expr`, appending to an `ecs_strbuf_t` instead.
pub extern fn ecs_ptr_to_expr_buf(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque, buf: *ecs_strbuf_t) c_int;

/// Serialize a value for reading rather than for parsing: the same as `ecs_ptr_to_expr`
/// except that strings come out unquoted. Free the result with `ecs_os_free`.
pub extern fn ecs_ptr_to_str(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque) ?[*:0]u8;

/// Same as `ecs_ptr_to_str`, appending to an `ecs_strbuf_t` instead.
pub extern fn ecs_ptr_to_str_buf(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque, buf: *ecs_strbuf_t) c_int;

pub const ecs_expr_node_t = opaque {};

/// Import the script module, the equivalent of `ECS_IMPORT(world, FlecsScript)` in C.
pub extern fn FlecsScriptImport(world: *ecs_world_t) void;

//=============================================================================
// Doc
//=============================================================================

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

//=============================================================================
// Meta — runtime reflection
//=============================================================================

pub extern const EcsQuantity: ecs_entity_t;

/// One of the `Ecs*Type` constants. Declared as the integer the C enum compiles to, so
/// that a value flecs invents at runtime is representable.
pub const ecs_type_kind_t = c_uint;

/// Added to every entity that has reflection data.
pub const EcsType = extern struct {
    kind: ecs_type_kind_t = 0,
    /// Whether the type already existed rather than being created from reflection data.
    existing: bool = false,
    /// Whether the reflection data describes only part of the type.
    partial: bool = false,
};

/// One of the `EcsBool`..`EcsId` constants. Declared as the integer the C enum compiles
/// to, for the same reason as `ecs_type_kind_t`.
pub const ecs_primitive_kind_t = c_uint;

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

pub const ecs_member_value_range_t = extern struct {
    min: f64 = 0,
    max: f64 = 0,
};

/// Added to a member entity to say which values are sensible, which are worth a warning,
/// and which are wrong. Nothing enforces them; they are there for a UI to render.
pub const EcsMemberRanges = extern struct {
    value: ecs_member_value_range_t = .{},
    warning: ecs_member_value_range_t = .{},
    @"error": ecs_member_value_range_t = .{},
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
pub const ecs_meta_op_kind_t = c_uint;

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

pub const ecs_primitive_desc_t = extern struct {
    /// Existing entity to attach the type to. 0 creates one.
    entity: ecs_entity_t = 0,
    kind: ecs_primitive_kind_t = 0,
};

/// Register a primitive type. 0 on failure. This and the other `ecs_*_init` operations
/// below are what flecs's `ecs_primitive`, `ecs_enum` and friends expand to.
pub extern fn ecs_primitive_init(world: *ecs_world_t, desc: *const ecs_primitive_desc_t) ecs_entity_t;

pub const ecs_enum_desc_t = extern struct {
    /// Existing entity to attach the type to. 0 creates one.
    entity: ecs_entity_t = 0,
    /// Terminated by the first entry with a null name.
    constants: [32]ecs_enum_constant_t = @splat(.{}),
    underlying_type: ecs_entity_t = 0,
};

/// Register an enum type. 0 on failure.
pub extern fn ecs_enum_init(world: *ecs_world_t, desc: *const ecs_enum_desc_t) ecs_entity_t;

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

/// Append a member to a struct type, adding the `EcsStruct` component first if the
/// entity is not a struct type yet.
pub extern fn ecs_struct_add_member(world: *ecs_world_t, @"type": ecs_entity_t, member: *const ecs_member_t) c_int;

/// Find a struct member by name. Null when the type is not a struct or has no such
/// member. The pointer aims into the type's members vector, so adding a member
/// invalidates it.
pub extern fn ecs_struct_get_member(world: *ecs_world_t, @"type": ecs_entity_t, name: [*:0]const u8) ?*ecs_member_t;

/// Same as `ecs_struct_get_member`, by index rather than name.
pub extern fn ecs_struct_get_nth_member(world: *ecs_world_t, @"type": ecs_entity_t, i: i32) ?*ecs_member_t;

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

//=============================================================================
// OS API implementation
//=============================================================================

/// Install the platform's default OS API: allocation, threading, timing, and the rest of
/// `ecs_os_api_t`. flecs calls this itself unless the build turned it off, so the reason
/// to call it by hand is to reinstate the defaults after overriding some of them.
pub extern fn ecs_set_os_api_impl() void;

//=============================================================================
// Modules
//=============================================================================

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

comptime {
    // Nothing in this file may depend on the host's C ABI beyond what flecs itself
    // assumes: ids are 64 bits wide and sizes are 32-bit signed.
    std.debug.assert(@sizeOf(ecs_id_t) == 8);
    std.debug.assert(@sizeOf(ecs_size_t) == 4);
}
