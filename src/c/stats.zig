//! flecs C declarations for statistics.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const alerts = @import("alerts.zig");
const core = @import("core.zig");
const metrics = @import("metrics.zig");

// Re-exported so a caller of this module sees one namespace rather than
// having to know which area a shared declaration came from.
pub const ecs_alert_desc_t = alerts.ecs_alert_desc_t;
pub const ecs_alert_init = alerts.ecs_alert_init;
pub const ecs_get_alert_count = alerts.ecs_get_alert_count;
pub const ecs_allocator_memory_t = core.ecs_allocator_memory_t;
pub const ecs_component_index_memory_t = core.ecs_component_index_memory_t;
pub const ecs_component_memory_t = core.ecs_component_memory_t;
pub const ecs_component_record_t = core.ecs_component_record_t;
pub const ecs_entities_memory_t = core.ecs_entities_memory_t;
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_float_t = core.ecs_float_t;
pub const ecs_ftime_t = core.ecs_ftime_t;
pub const ecs_get_pipeline = core.ecs_get_pipeline;
pub const ecs_misc_memory_t = core.ecs_misc_memory_t;
pub const ecs_query_memory_t = core.ecs_query_memory_t;
pub const ecs_query_t = core.ecs_query_t;
pub const ecs_size_t = core.ecs_size_t;
pub const ecs_table_histogram_t = core.ecs_table_histogram_t;
pub const ecs_table_memory_t = core.ecs_table_memory_t;
pub const ecs_table_t = core.ecs_table_t;
pub const ecs_vec_t = core.ecs_vec_t;
pub const ecs_world_t = core.ecs_world_t;
pub const ecs_metric_desc_t = metrics.ecs_metric_desc_t;
pub const ecs_metric_init = metrics.ecs_metric_init;

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
