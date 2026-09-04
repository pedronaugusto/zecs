//! What a world is doing: statistics, metrics and alerts.
//!
//! The stats structs stay raw, and that is the point. `ecs_world_stats_t` is tens of
//! kilobytes of `ecs_metric_t` — sixty-odd named fields, each a sliding window of sixty
//! samples — and mirroring those names into Zig would add sixty declarations that carry
//! no type information the C struct did not already have, and one more place for a name
//! to drift. So the struct is `zecs.c.stats.ecs_world_stats_t`, filled by
//! `zecs.c.stats.ecs_world_stats_get`, and what this module adds is the part that is actually
//! easy to get wrong: reading one metric out of it.
//!
//! For the same reason the `reduce`, `reduce_last`, `repeat_last` and `copy_last`
//! families are raw. They move samples between two structs of the same type and take no
//! untyped parameter, return no sentinel and own nothing. `ecs_world_stats_log` is raw
//! too; it prints through flecs's logger rather than returning anything.
//!
//! `ecs_pipeline_stats_t` is the exception, and it earns a type here: it holds two
//! `ecs_vec_t`s that have to be freed, and reading them means casting an untyped
//! pointer and an `i32` count into a slice.

const std = @import("std");
const c_alerts = @import("c/alerts.zig");
const c_metrics = @import("c/metrics.zig");
const c = @import("c/stats.zig");
const options = @import("zecs_options");
const types = @import("types.zig");
const world_mod = @import("world.zig");
const Error = @import("error.zig").Error;

const Entity = types.Entity;
const Id = types.Id;
const World = world_mod.World;

//=============================================================================
// Reading a metric
//
// `ecs_metric_t` is a union of a gauge and a counter over a ring of samples, and the
// struct that holds it carries the cursor saying which slot is current. Nothing in the
// union says which member is live — the recording site decided that, and a reader has
// to know — and nothing in the metric says where the cursor is.
//
// The two mistakes that follow are the reason this exists: reading the wrong slot, and
// looking for the cursor in the wrong place. Both hand back a number rather than an
// error.
//=============================================================================

/// Samples flecs keeps per metric. Derived from the struct the ABI guard checks rather
/// than written down a second time.
pub const window_size: usize = @typeInfo(@FieldType(c.ecs_gauge_t, "avg")).array.len;

/// One sample of a gauge: a quantity measured at a point in time.
///
/// flecs writes the same value into all three when it records a gauge; `min` and `max`
/// only diverge from `avg` after a `reduce` has folded several samples into one.
pub const Gauge = struct {
    avg: c.ecs_float_t,
    min: c.ecs_float_t,
    max: c.ecs_float_t,
};

/// One sample of a counter: a total that only goes up, and how fast it went up.
pub const Counter = struct {
    /// The running total at this sample.
    total: f64,
    /// How much it grew since the previous sample. This is the same memory a gauge
    /// reading of the metric returns.
    rate: Gauge,
};

/// The cursor into a stats struct's sliding window.
///
/// ```zig
/// var stats: zecs.c.stats.ecs_world_stats_t = .{};
/// zecs.c.stats.ecs_world_stats_get(world.raw, &stats);
///
/// const w = zecs.stats.Window.of(&stats);
/// const entities = w.gauge(&stats.entities.count).avg;
/// const frames = w.counter(&stats.frame.frame_count).total;
/// ```
///
/// Keep the struct and call `ecs_world_stats_get` again each frame to fill the window;
/// a fresh struct every time gives a window of one.
pub const Window = struct {
    /// The slot the most recent sample went into.
    at: i32,

    /// Finds the cursor for a stats struct.
    ///
    /// Takes a pointer to any of flecs's stats structs. `ecs_system_stats_t` is the one
    /// worth having this for: it keeps no cursor of its own and shares the one on the
    /// query stats it embeds, so the field is not where a reader would look for it.
    pub inline fn of(stats: anytype) Window {
        const Stats = @TypeOf(stats.*);
        if (@hasField(Stats, "t")) return .{ .at = stats.t };
        return .{ .at = stats.query.t };
    }

    /// The current value of a metric read as a gauge.
    ///
    /// Reading a counter this way is meaningful and gives its rate: flecs stores a
    /// counter's rate in the same bytes the gauge occupies. Reading a gauge as a
    /// counter is not, so the two are separate calls.
    pub inline fn gauge(self: Window, m: *const c.ecs_metric_t) Gauge {
        const slot: usize = @intCast(self.at);
        return .{
            .avg = m.gauge.avg[slot],
            .min = m.gauge.min[slot],
            .max = m.gauge.max[slot],
        };
    }

    /// The current value of a metric read as a counter.
    pub inline fn counter(self: Window, m: *const c.ecs_metric_t) Counter {
        const slot: usize = @intCast(self.at);
        return .{
            .total = m.counter.value[slot],
            .rate = self.gauge(m),
        };
    }
};

//=============================================================================
// Pipeline statistics
//=============================================================================

/// A sample of what a pipeline is running.
///
/// Owns two vectors flecs allocated, so it has a `deinit`. Sampling repeatedly into
/// the same value is what fills the window, and what the vectors are reused for.
///
/// ```zig
/// var stats: zecs.stats.PipelineStats = .{};
/// defer stats.deinit();
///
/// if (stats.sample(world, zecs.c.core.ecs_get_pipeline(world.raw))) {
///     for (stats.systems()) |system| { ... }
/// }
/// ```
pub const PipelineStats = struct {
    raw: c.ecs_pipeline_stats_t = .{},

    /// Samples the pipeline.
    ///
    /// False means there was nothing to sample — the entity is not a pipeline, or it
    /// is one that matches no systems yet. That is not a failure, and nothing was
    /// allocated on that path.
    ///
    /// Needs the stats and pipeline addons.
    pub fn sample(self: *PipelineStats, world: World, pipeline: Entity) bool {
        if (comptime !(options.addon_stats and options.addon_pipeline)) @compileError(
            "zecs.stats.PipelineStats needs the stats and pipeline addons",
        );
        return c.ecs_pipeline_stats_get(world.raw, pipeline, &self.raw);
    }

    /// Releases the vectors flecs allocated. Safe on a value that was never sampled.
    ///
    /// Needs the stats and pipeline addons, like `sample`: `ecs_pipeline_stats_fini` is
    /// compiled into flecs only when both are defined, so a build without them has no
    /// such symbol to link against.
    pub fn deinit(self: *PipelineStats) void {
        if (comptime !(options.addon_stats and options.addon_pipeline)) @compileError(
            "zecs.stats.PipelineStats needs the stats and pipeline addons",
        );
        c.ecs_pipeline_stats_fini(&self.raw);
        self.raw = .{};
    }

    /// The systems the pipeline ran, in the order it ran them.
    ///
    /// A zero in this slice is not a system: it marks a synchronisation point, where
    /// the pipeline merged the command queues of its worker threads before going on.
    /// The last element is always one of those.
    pub fn systems(self: *const PipelineStats) []const Entity {
        return vecSlice(Entity, &self.raw.systems);
    }

    /// One entry per synchronisation point, in the same order they appear in `systems`.
    ///
    /// Each carries metrics of its own; `Window.of(&stats.raw)` is the cursor to read
    /// them at.
    pub fn syncPoints(self: *const PipelineStats) []const c.ecs_sync_stats_t {
        return vecSlice(c.ecs_sync_stats_t, &self.raw.sync_points);
    }
};

/// An `ecs_vec_t` as a slice. flecs stores the element type nowhere, so the caller
/// supplies it; every use in this file is against a vector flecs documents the element
/// type of.
fn vecSlice(comptime T: type, vec: *const c.ecs_vec_t) []const T {
    const array = vec.array orelse return &.{};
    const ptr: [*]const T = @ptrCast(@alignCast(array));
    return ptr[0..@intCast(vec.count)];
}

//=============================================================================
// Metrics
//=============================================================================

/// How a metric interprets what it samples.
pub const MetricKind = enum {
    /// A quantity that goes up and down. The member's value, or the number of entities
    /// with the id.
    gauge,
    /// A total that only goes up, sampled from the member's current value.
    counter,
    /// A total that only goes up, increased by the member's value each sample. Only
    /// valid with `member` or `dotmember`.
    counter_increment,
    /// A total that only goes up, counting entities with the id. Cannot be combined
    /// with a member.
    counter_id,

    /// The entity flecs assigned to this kind. Zero until the metrics module has been
    /// imported — see `zecs.pipeline.importBuiltin`.
    ///
    /// Needs the metrics addon: the four entities are linked symbols flecs only defines
    /// with it, so `MetricDesc.toC` needs it too.
    pub inline fn id(self: MetricKind) Entity {
        if (comptime !options.addon_metrics) @compileError(
            "zecs.stats.MetricKind.id needs the metrics addon: build with -Daddon_metrics=true",
        );
        return switch (self) {
            .gauge => c_metrics.EcsGauge,
            .counter => c_metrics.EcsCounter,
            .counter_increment => c_metrics.EcsCounterIncrement,
            .counter_id => c_metrics.EcsCounterId,
        };
    }
};

/// What a metric samples.
///
/// Exactly one source is required: a `member` (or `dotmember`), or an `id`. flecs
/// rejects a descriptor with neither.
pub const MetricDesc = struct {
    name: ?[:0]const u8 = null,

    /// Reuse an existing entity as the metric rather than making one.
    entity: Entity = 0,

    /// A struct member, as registered with the meta addon, whose value is sampled.
    member: Entity = 0,

    /// A dotted path to a member, resolved against `id` — `"velocity.x"`. Use instead
    /// of `member` when the value is nested.
    dotmember: ?[:0]const u8 = null,

    /// The component, tag or pair to sample. With `member`, the component the member
    /// belongs to; on its own, the thing being counted.
    id: Id = 0,

    /// Sample one value per relationship target rather than one for the pair. `id`
    /// must then be a pair whose second element is a wildcard.
    targets: bool = false,

    kind: MetricKind = .gauge,

    /// A one-line description, stored through the doc addon. Ignored, with a warning,
    /// in a build without it.
    brief: ?[:0]const u8 = null,

    /// Fills in a C descriptor, for the fields this wrapper does not cover.
    pub fn toC(self: MetricDesc, entity: Entity) c.ecs_metric_desc_t {
        return .{
            .entity = entity,
            .member = self.member,
            .dotmember = if (self.dotmember) |d| d.ptr else null,
            .id = self.id,
            .targets = self.targets,
            .kind = self.kind.id(),
            .brief = if (self.brief) |b| b.ptr else null,
        };
    }
};

/// Creates a metric and returns the entity that carries it.
///
/// Import the metrics module first: without it the kind entities are all zero and
/// flecs rejects the descriptor for having no kind at all.
///
/// Needs the metrics addon.
pub fn metric(world: World, desc: MetricDesc) Error!Entity {
    if (comptime !options.addon_metrics) @compileError(
        "zecs.stats.metric needs the metrics addon: build with -Daddon_metrics=true",
    );

    const entity = if (desc.entity != 0)
        desc.entity
    else if (desc.name) |name|
        try world.entity(.{ .name = name })
    else
        0;

    const c_desc = desc.toC(entity);
    const id = c.ecs_metric_init(world.raw, &c_desc);
    if (id == 0) return Error.MetricInitFailed;
    return id;
}

//=============================================================================
// Alerts
//=============================================================================

/// How bad an alert is.
pub const Severity = enum {
    info,
    warning,
    /// `EcsAlertError`, and the default. Spelled without the second syllable because
    /// `error` is a keyword.
    err,
    critical,

    /// The entity flecs assigned to this severity. Zero until the alerts module has
    /// been imported — see `zecs.pipeline.importBuiltin`.
    ///
    /// Needs the alerts addon: the four entities are linked symbols flecs only defines
    /// with it, so `AlertDesc.toC` needs it too.
    pub inline fn id(self: Severity) Entity {
        if (comptime !options.addon_alerts) @compileError(
            "zecs.stats.Severity.id needs the alerts addon: build with -Daddon_alerts=true",
        );
        return switch (self) {
            .info => c_alerts.EcsAlertInfo,
            .warning => c_alerts.EcsAlertWarning,
            .err => c_alerts.EcsAlertError,
            .critical => c_alerts.EcsAlertCritical,
        };
    }
};

/// Raises an alert's severity for the entities that also match `with`.
pub const SeverityFilter = struct {
    severity: Severity,
    /// The id an entity must also have for this severity to apply. Required: flecs
    /// ignores a filter with no id and rejects one with an id but no severity.
    with: Id,
    /// Apply the filter to a query variable rather than to the matched entity. The
    /// name must resolve against the alert's query.
    variable: ?[:0]const u8 = null,
};

/// The most severity filters flecs stores on one alert. Fixed in the header, not a
/// build option.
pub const severity_filter_max = @typeInfo(
    @FieldType(c.ecs_alert_desc_t, "severity_filters"),
).array.len;

/// A query that is evaluated periodically, raising an alert for every entity it
/// matches.
pub const AlertDesc = struct {
    name: ?[:0]const u8 = null,

    /// Reuse an existing entity as the alert rather than making one.
    entity: Entity = 0,

    /// What the alert looks for. Must constrain the matched entity itself — flecs
    /// refuses a query with no `$this` term, because an alert with nothing to point at
    /// has nothing to report.
    query: types.QueryDesc = .{},

    /// The message reported for each match. flecs interpolates query variables into it
    /// through the script addon, and copies the string.
    message: ?[:0]const u8 = null,

    /// A display name, stored through the doc addon. flecs fails the alert outright,
    /// rather than warning, in a build without it.
    doc_name: ?[:0]const u8 = null,

    /// A one-line description, stored through the doc addon. Same as `doc_name`: it
    /// fails without that addon.
    brief: ?[:0]const u8 = null,

    severity: Severity = .err,

    /// Conditions that raise the severity above `severity`. At most
    /// `severity_filter_max` of them.
    severity_filters: []const SeverityFilter = &.{},

    /// How long an alert stays active after its entity stops matching. Zero clears it
    /// on the first evaluation that no longer matches.
    retain_period: c.ecs_ftime_t = 0,

    /// Alert on a member's value leaving the warning or error range declared for it
    /// with the meta addon, rather than on the query matching at all. The member must
    /// have those ranges, or flecs refuses the alert.
    member: Entity = 0,

    /// The component `member` belongs to. Derived from the member's parent when left
    /// at zero.
    id: Id = 0,

    /// Read `member` from a query variable rather than from the matched entity.
    variable: ?[:0]const u8 = null,

    /// Fills in a C descriptor, for the fields this wrapper does not cover.
    pub fn toC(self: AlertDesc, entity: Entity) Error!c.ecs_alert_desc_t {
        if (self.severity_filters.len > severity_filter_max) {
            return Error.TooManySeverityFilters;
        }

        var desc = c.ecs_alert_desc_t{
            .entity = entity,
            .query = try self.query.toC(),
            .message = if (self.message) |m| m.ptr else null,
            .doc_name = if (self.doc_name) |d| d.ptr else null,
            .brief = if (self.brief) |b| b.ptr else null,
            .severity = self.severity.id(),
            .retain_period = self.retain_period,
            .member = self.member,
            .id = self.id,
            .@"var" = if (self.variable) |v| v.ptr else null,
        };

        for (self.severity_filters, 0..) |filter, i| {
            desc.severity_filters[i] = .{
                .severity = filter.severity.id(),
                .with = filter.with,
                .@"var" = if (filter.variable) |v| v.ptr else null,
            };
        }

        return desc;
    }
};

/// Creates an alert and returns the entity that carries it.
///
/// Import the alerts module first. Alerts are evaluated by two systems flecs installs
/// on `PreStore` and `OnStore` with an interval of half a second, so an alert only
/// appears once the world has been progressed far enough for that interval to elapse,
/// and it clears the same way. Read the result with `zecs.c.alerts.ecs_get_alert_count`.
///
/// Needs the alerts addon.
pub fn alert(world: World, desc: AlertDesc) Error!Entity {
    if (comptime !options.addon_alerts) @compileError(
        "zecs.stats.alert needs the alerts addon: build with -Daddon_alerts=true",
    );

    // Validate before creating the entity, so a rejected descriptor leaves nothing
    // named behind.
    var c_desc = try desc.toC(0);
    c_desc.entity = if (desc.entity != 0)
        desc.entity
    else if (desc.name) |name|
        try world.entity(.{ .name = name })
    else
        0;

    const id = c.ecs_alert_init(world.raw, &c_desc);
    if (id == 0) return Error.AlertInitFailed;
    return id;
}

//=============================================================================
// Tests
//=============================================================================

test "the window size comes from the struct flecs compiled" {
    try std.testing.expectEqual(@as(usize, 60), window_size);
}

test "a gauge and a counter read the same bytes for the rate" {
    // flecs lays `ecs_counter_t` out as a gauge followed by the totals, in a union with
    // the bare gauge — so recording a counter also records its rate where a gauge
    // reading finds it. A binding that got this wrong would still compile.
    var m = std.mem.zeroes(c.ecs_metric_t);
    m.counter.rate.avg[7] = 3;
    m.counter.value[7] = 100;

    const w = Window{ .at = 7 };
    try std.testing.expectEqual(@as(c.ecs_float_t, 3), w.gauge(&m).avg);
    try std.testing.expectEqual(@as(f64, 100), w.counter(&m).total);
    try std.testing.expectEqual(@as(c.ecs_float_t, 3), w.counter(&m).rate.avg);
}

test "the cursor of system stats comes from its query stats" {
    var world_stats = c.ecs_world_stats_t{};
    world_stats.t = 11;
    try std.testing.expectEqual(@as(i32, 11), Window.of(&world_stats).at);

    var system_stats = c.ecs_system_stats_t{};
    system_stats.query.t = 23;
    try std.testing.expectEqual(@as(i32, 23), Window.of(&system_stats).at);
}

test "an alert with too many severity filters is refused rather than truncated" {
    // Building the descriptor reads the severity entities, which only exist in a build
    // with the alerts addon.
    if (comptime !options.addon_alerts) return error.SkipZigTest;

    const filters = [_]SeverityFilter{
        .{ .severity = .warning, .with = 1 },
    } ** (severity_filter_max + 1);
    const desc = AlertDesc{ .severity_filters = &filters };
    try std.testing.expectError(Error.TooManySeverityFilters, desc.toC(0));
}

test "an empty vector reads as an empty slice" {
    const vec = c.ecs_vec_t{};
    try std.testing.expectEqual(@as(usize, 0), vecSlice(Entity, &vec).len);
}
