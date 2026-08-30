//! The scheduler: pipelines, phases and modules.
//!
//! A pipeline is a query over systems, ordered by the phase each system depends on.
//! `World.progress` runs the world's current pipeline; everything here is about
//! building a different one, or adding a phase to the one flecs starts with.
//!
//! Three parts of this area are deliberately not wrapped, because a wrapper would be a
//! second name for the same call and nothing more:
//!
//! - `ecs_set_pipeline`, `ecs_get_pipeline`, `ecs_run_pipeline` and
//!   `ecs_using_task_threads` take and return exactly what the typed layer would.
//! - The whole timer API — `ecs_set_interval`, `ecs_set_timeout`, `ecs_set_rate`,
//!   `ecs_set_tick_source`, `ecs_start_timer` and the rest. They already speak
//!   `ecs_ftime_t`, which follows `-Dftime_t`, and the zero they can return comes from
//!   an `ecs_check` that aborts in a checked build and is compiled out of a release
//!   one. There is no reachable failure to turn into an error and no untyped parameter
//!   to remove. `zecs.c.timer.ecs_set_interval(world.raw, 0, 0.5)` is the binding.
//! - `ecs_import_from_library` loads a module out of a shared object, which is
//!   `std.DynLib` territory, and `ecs_import_c`/`ecs_module_init` are the C spellings
//!   of what `import` below does with a comptime type.
//!
//! What is worth knowing about timers, since no signature says it: a tick source is an
//! entity, `ecs_set_interval(world, 0, dt)` creates one and returns it, and a system
//! only follows it after `ecs_set_tick_source`. `ProgressTimers` advances every timer
//! in `PreFrame` from the raw delta passed to `progress`, so a timer measures the time
//! the caller reports rather than the time that passed.

const std = @import("std");
const c = @import("c/pipeline.zig");
const options = @import("zecs_options");
const types = @import("types.zig");
const world_mod = @import("world.zig");
const query_mod = @import("query.zig");
const Error = @import("error.zig").Error;

const Entity = types.Entity;
const Id = types.Id;
const World = world_mod.World;

//=============================================================================
// Pipelines
//=============================================================================

/// What a pipeline matches, and in what order.
///
/// The query decides both which systems belong to the pipeline and how they are
/// sorted, so a pipeline query is not an ordinary one: it wants a `Cascade` term over
/// `DependsOn` to order the phases, and it usually wants to exclude disabled systems.
/// flecs's own pipeline is
///
/// ```text
/// System, Phase(cascade|DependsOn), !(DependsOn, OnStart), !Disabled(up|DependsOn),
///     !Disabled(up|ChildOf)
/// ```
///
/// with `order_by` set to compare entity ids, which is what breaks ties between two
/// systems in the same phase.
///
/// **A pipeline with no `order_by` runs the systems of one phase in table order**, which
/// is an ordering nothing in the program controls and which changes when an unrelated
/// system is added: two systems in `OnUpdate` that write the same component would then
/// run in either order from build to build. That is a difference in behaviour, not in the
/// last bits of a number, so this type does not offer it as a default. `toC` installs
/// `Query.orderByEntityId` — flecs's own tie-break, which is creation order — whenever
/// `query.options.order_by` is null. Set that field to sort by something else.
pub const PipelineDesc = struct {
    /// A name, so the pipeline is legible in an inspector. Taken literally, dots and
    /// all, like every other name in this package.
    name: ?[:0]const u8 = null,

    /// Reuse an existing entity rather than making one. The entity must not already
    /// carry a pipeline; use `zecs.c.pipeline.ecs_pipeline_update` to replace one that does.
    entity: Entity = 0,

    /// What the pipeline runs, and in what order.
    query: types.QueryDesc = .{},

    /// Fills in a C descriptor, for the fields this wrapper does not cover.
    ///
    /// Supplies the entity-id tie-break when the caller set no ordering — see the note
    /// on this type. A caller who set one keeps it.
    pub fn toC(self: PipelineDesc, entity: Entity) Error!c.ecs_pipeline_desc_t {
        var query = self.query;
        if (query.options.order_by == null) {
            query.options.order_by = .{ .compare = query_mod.orderByEntityId };
        }
        return .{
            .entity = entity,
            .query = try query.toC(),
        };
    }
};

/// Creates a pipeline and returns the entity that carries it.
///
/// Needs the pipeline addon. Setting it as the world's pipeline is
/// `zecs.c.pipeline.ecs_set_pipeline`, which needs no wrapper.
pub fn create(world: World, desc: PipelineDesc) Error!Entity {
    if (comptime !options.addon_pipeline) @compileError(
        "zecs.pipeline.create needs the pipeline addon: build with -Daddon_pipeline=true",
    );

    // The descriptor is validated before the entity is created, so a rejected
    // descriptor does not leave a stray named entity in the world.
    var c_desc = try desc.toC(0);
    c_desc.entity = if (desc.entity != 0)
        desc.entity
    else if (desc.name) |name|
        try world.entity(.{ .name = name })
    else
        0;

    const id = c.ecs_pipeline_init(world.raw, &c_desc);
    if (id == 0) return Error.PipelineInitFailed;
    return id;
}

//=============================================================================
// Phases
//=============================================================================

/// Where a custom phase sits in the frame.
pub const PhaseDesc = struct {
    name: ?[:0]const u8 = null,

    /// The phase this one runs after — `Builtin.on_update.id()`, or another custom
    /// phase. Left at zero the phase has no predecessor, which puts it at the front
    /// alongside `PreFrame`.
    after: Entity = 0,
};

/// Creates a phase that systems can be assigned to with `SystemDesc.phase`.
///
/// A phase is two things at once, and forgetting either is silent: the entity has to
/// carry the `Phase` tag, or the pipeline query does not match systems that depend on
/// it and they never run; and it has to have a `DependsOn` pair, or the `Cascade` term
/// has no depth to sort it by and its position in the frame is whatever the table
/// order happens to be. This does both, which is the whole reason it exists — it wraps
/// no single C call.
///
/// Needs the pipeline addon, which is what defines the `Phase` tag.
pub fn phase(world: World, desc: PhaseDesc) Error!Entity {
    if (comptime !options.addon_pipeline) @compileError(
        "zecs.pipeline.phase needs the pipeline addon: build with -Daddon_pipeline=true",
    );

    var add: [2]Id = undefined;
    var count: usize = 0;

    add[count] = types.Builtin.phase.id();
    count += 1;

    if (desc.after != 0) {
        add[count] = types.pair(types.Builtin.depends_on.id(), desc.after);
        count += 1;
    }

    return world.entity(.{ .name = desc.name, .add = add[0..count] });
}

//=============================================================================
// Modules
//
// A module in C is a function pointer and a name that have to agree: `ecs_import`
// looks the name up, calls the function if it found nothing, and then looks it up
// again — so a module whose function registers itself under a different name is
// reported as undefined. In Zig the pair collapses into one comptime type, and the
// thunk that flecs stores is generated rather than written.
//=============================================================================

/// Imports a module, running its `import` declaration once per world.
///
/// A module is any type with `pub fn import(world: World) void`, or the same returning
/// `Error!void`. The name comes from `pub const name` if the type declares one, and
/// otherwise from the last segment of `@typeName` — so a module declared as
/// `const Movement = struct { ... }` is imported as `Movement`.
///
/// flecs reads that name as PascalCase and turns it into a scope path: `Movement`
/// becomes the entity `movement`, and `GameCore` becomes `game.core`, a child `core`
/// under a scope `game`. Everything the import function creates is nested under it,
/// because flecs sets the scope for the duration of the call.
///
/// ```zig
/// const Movement = struct {
///     pub fn import(world: zecs.World) zecs.Error!void {
///         const position = try world.component(Position, .{});
///         _ = try world.system(.{ .name = "Move", .phase = ..., ... });
///     }
/// };
///
/// _ = try zecs.pipeline.import(world, Movement);
/// ```
///
/// Importing the same module twice into one world is a lookup and nothing else, which
/// is what makes a module a safe way for two unrelated parts of a program to depend on
/// the same components. Importing it into a second world runs it again and gives that
/// world an entity of its own; flecs's own `ECS_MODULE_DEFINE` keeps the module entity
/// in a variable that outlives the world, and makes the second world revive the first
/// one's id instead.
///
/// An error from the import leaves the module entity behind, because flecs creates it
/// before the module body runs. Importing again after a failure is therefore the same
/// lookup as importing after a success, and will not retry.
///
/// Needs the module addon.
pub fn import(world: World, comptime M: type) Error!Entity {
    if (comptime !options.addon_module) @compileError(
        "zecs.pipeline.import needs the module addon: build with -Daddon_module=true",
    );

    const name = comptime moduleName(M);

    const Thunk = struct {
        // flecs's import callback returns nothing, so an error raised by the module has
        // to be carried out of band. One slot per module type, written and read either
        // side of a synchronous call; importing is world setup, and flecs refuses it on
        // a world that is being iterated.
        var failure: ?Error = null;

        fn call(raw: *c.ecs_world_t) callconv(.c) void {
            // What `ECS_MODULE` does, and in the order it does it: register the entity
            // `ecs_import` is about to look for, then make it the scope, so everything
            // the module creates is nested under it. `ecs_module_init` restores the
            // scope it found rather than setting the new one, so the second
            // call is not optional. `ecs_import` puts the old scope back afterwards.
            const module = c.ecs_module_init(raw, name.ptr, &.{});
            _ = c.ecs_set_scope(raw, module);

            const w = World{ .raw = raw };
            const Result = @typeInfo(@TypeOf(M.import)).@"fn".return_type.?;
            if (Result == void) {
                M.import(w);
            } else {
                M.import(w) catch |err| {
                    failure = err;
                };
            }
        }
    };

    Thunk.failure = null;
    const id = c.ecs_import(world.raw, &Thunk.call, name.ptr);
    if (Thunk.failure) |err| return err;
    if (id == 0) return Error.ModuleImportFailed;
    return id;
}

/// The flecs modules `World.init` does not import for you.
///
/// `ecs_init` imports system, pipeline, timer, meta, doc, script and rest, and stops
/// there. Stats, metrics and alerts are compiled in but not imported, and the
/// functions they provide read component ids that are still zero until they are — so
/// `stats.metric` and `stats.alert` fail, or abort, against a world that has not asked
/// for them.
pub const BuiltinModule = enum {
    /// `FlecsStats`, which runs the systems that sample the world every frame and store
    /// the result in components. Reading stats directly with `ecs_world_stats_get` does
    /// not need it.
    stats,
    /// `FlecsMetrics`, which `stats.metric` needs. Pulls in meta and units.
    metrics,
    /// `FlecsAlerts`, which `stats.alert` needs. Pulls in metrics, and therefore meta,
    /// units, pipeline and timer.
    alerts,
};

/// Imports one of the modules flecs ships but does not import on its own.
///
/// The name a module registered itself under has to match the one `ecs_import` looks
/// up, and pairing them wrongly is reported as a module that does not exist rather
/// than as a bad argument. This removes the pairing.
pub fn importBuiltin(world: World, comptime module: BuiltinModule) Error!Entity {
    if (comptime !options.addon_module) @compileError(
        "zecs.pipeline.importBuiltin needs the module addon: build with -Daddon_module=true",
    );

    const id = switch (module) {
        .stats => blk: {
            if (comptime !options.addon_stats) @compileError(
                "zecs.pipeline.importBuiltin(.stats) needs the stats addon",
            );
            break :blk c.ecs_import(world.raw, &c.FlecsStatsImport, "FlecsStats");
        },
        .metrics => blk: {
            if (comptime !options.addon_metrics) @compileError(
                "zecs.pipeline.importBuiltin(.metrics) needs the metrics addon",
            );
            break :blk c.ecs_import(world.raw, &c.FlecsMetricsImport, "FlecsMetrics");
        },
        .alerts => blk: {
            if (comptime !options.addon_alerts) @compileError(
                "zecs.pipeline.importBuiltin(.alerts) needs the alerts addon",
            );
            break :blk c.ecs_import(world.raw, &c.FlecsAlertsImport, "FlecsAlerts");
        },
    };

    if (id == 0) return Error.ModuleImportFailed;
    return id;
}

/// The name a module type is imported under.
fn moduleName(comptime M: type) [:0]const u8 {
    if (@hasDecl(M, "name")) return M.name;
    // `@typeName` is a scoped path — the file, any enclosing function, then the type —
    // and flecs reads its own separator into the name, so only the last segment can be
    // handed over. Resolved at compile time, because the result has to keep the
    // terminating zero of the array `@typeName` points at.
    return comptime blk: {
        const full: [:0]const u8 = @typeName(M);
        const start = if (std.mem.lastIndexOfScalar(u8, full, '.')) |i| i + 1 else 0;
        break :blk full[start.. :0];
    };
}

test "a module type is named after its last path segment" {
    const Movement = struct {};
    try std.testing.expectEqualStrings("Movement", moduleName(Movement));
}

test "a module type can name itself" {
    const Movement = struct {
        pub const name: [:0]const u8 = "GameMovement";
    };
    try std.testing.expectEqualStrings("GameMovement", moduleName(Movement));
}

test "a pipeline descriptor refuses more terms than the build allows" {
    const terms = [_]types.Term{.{ .id = 1 }} ** (types.term_count_max + 1);
    const desc = PipelineDesc{ .query = .{ .terms = &terms } };
    try std.testing.expectError(Error.TooManyTerms, desc.toC(0));
}
