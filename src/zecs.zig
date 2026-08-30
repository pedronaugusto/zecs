//! zecs — Zig bindings for [flecs](https://github.com/SanderMertens/flecs).
//!
//! A typed layer over the flecs C API, with the vendored library pinned and unmodified,
//! the host's allocator in charge of every allocation flecs makes, and the boundary
//! between the hand-written externs and the compiled C checked by tests rather than
//! trusted.
//!
//! ```zig
//! const zecs = @import("zecs");
//!
//! try zecs.setAllocator(gpa);              // before the first world, or it is an error
//!
//! const world = try zecs.World.init();
//! defer world.deinit();
//!
//! const position = try world.component(Position, .{});
//! const velocity = try world.component(Velocity, .{});
//!
//! const e = world.newEntity();
//! world.set(e, position, .{ .x = 0, .y = 0 });
//! world.set(e, velocity, .{ .x = 1, .y = 2 });
//!
//! _ = try world.system(.{
//!     .name = "Move",
//!     .phase = zecs.Builtin.on_update.id(),
//!     .query = .{ .terms = &.{
//!         .{ .id = position.asId(), .inout = .read_write },
//!         .{ .id = velocity.asId(), .inout = .read },
//!     } },
//!     .callback = zecs.callback(move),
//! });
//!
//! while (world.progress(1.0 / 60.0)) {}
//! ```
//!
//! ```zig
//! fn move(it: *zecs.Iter) void {
//!     const p = it.fieldSelf(Position, 0);
//!     const v = it.fieldSelf(Velocity, 1);
//!     for (p, v) |*pos, vel| {
//!         pos.x += vel.x * it.deltaTime();
//!         pos.y += vel.y * it.deltaTime();
//!     }
//! }
//! ```

const std = @import("std");

//=============================================================================
// The raw layer
//=============================================================================

/// flecs's C API, declared verbatim: `zecs.c.core.ecs_world_t`, `zecs.c.core.ecs_entity_init`,
/// `zecs.c.core.EcsOnUpdate`. Everything the typed layer is built from, available directly
/// for the parts it does not cover.
///
/// For anything not declared even there, link the artifact this package builds and
/// `@cImport` `flecs.h`: the header is installed for exactly that purpose.
/// The raw flecs declarations, one namespace per area — `c.entity`, `c.query`,
/// `c.meta` and so on. This is the escape hatch: anything the typed surface
/// does not wrap is reachable here, ABI-checked, and documented as a
/// first-class way to call it. The area is part of the path, so `core.ecs_new`
/// is `c.entity.ecs_new`.
pub const c = @import("c.zig");

/// Shorthand for the area this file itself happens to need.
const core = c.core;

/// The build options this package was compiled with — the addon set that was requested,
/// the allocator mode, the sizing constants. Branch on these instead of assuming.
pub const options = @import("zecs_options");

//=============================================================================
// Errors
//=============================================================================

const error_mod = @import("error.zig");
pub const Error = error_mod.Error;

//=============================================================================
// Memory
//=============================================================================

const memory = @import("memory.zig");

pub const setAllocator = memory.setAllocator;
pub const resetAllocator = memory.resetAllocator;
pub const allocatorInstalled = memory.allocatorInstalled;
pub const allocationStats = memory.stats;
pub const AllocationStats = memory.Stats;

//=============================================================================
// Core types
//=============================================================================

const types = @import("types.zig");

pub const Entity = types.Entity;
pub const Id = types.Id;
pub const Builtin = types.Builtin;
pub const InOut = types.InOut;
pub const Oper = types.Oper;
pub const CacheKind = types.CacheKind;
pub const Term = types.Term;
pub const TermRef = types.TermRef;
pub const QueryDesc = types.QueryDesc;
pub const QueryOptions = types.QueryOptions;

pub const pair = types.pair;
pub const pairFirst = types.pairFirst;
pub const pairSecond = types.pairSecond;
pub const isPair = types.isPair;

/// A string flecs allocated. Free it with its own `deinit`, not with the host's
/// allocator: flecs's strings come from the OS API's malloc and have to go back there.
pub const Str = types.Str;

/// Traversal flags, set on a term's source. See `Term`.
pub const Self = types.Self;
pub const Up = types.Up;
pub const Trav = types.Trav;
pub const Cascade = types.Cascade;
pub const Desc = types.Desc;

/// Limits this build was compiled with.
pub const term_count_max = types.term_count_max;
pub const event_count_max = types.event_count_max;

//=============================================================================
// The typed surface
//=============================================================================

const component_mod = @import("component.zig");
const world_mod = @import("world.zig");
const iter_mod = @import("iter.zig");
const query_mod = @import("query.zig");
const terms_mod = @import("terms.zig");
const system_mod = @import("system.zig");
const observer_mod = @import("observer.zig");
const table_mod = @import("table.zig");
const value_mod = @import("value.zig");
const script_mod = @import("script.zig");

pub const World = world_mod.World;
pub const EntityDesc = world_mod.EntityDesc;
pub const BulkDesc = World.BulkDesc;
pub const PathDesc = World.PathDesc;
pub const LookupDesc = World.LookupDesc;

/// The pair `(first, second)` as a typed component handle. See `world.zig`.
pub const pairOf = world_mod.pairOf;
pub const PairValue = world_mod.PairValue;

/// flecs's component lifecycle hooks, derived from a Zig type, and whether that type can
/// be copied into a second entity at all. See `component.zig`.
pub const typeHooks = component_mod.typeHooks;
pub const duplicable = component_mod.duplicable;

pub const Component = component_mod.Component;
pub const ComponentDesc = component_mod.ComponentDesc;

/// The strongest alignment flecs gives a component's storage, and the predicate the
/// typed layer refuses over. flecs's own limit — see `component.zig`.
pub const max_component_alignment = component_mod.max_alignment;
pub const componentIsStorable = component_mod.isStorable;

pub const Iter = iter_mod.Iter;
pub const Iterator = iter_mod.Iterator;
pub const callback = iter_mod.callback;

pub const Query = query_mod.Query;

/// The typed query: terms derived from a tuple of component handles, results handed back
/// as typed slices in the same order. `World.queryOf` builds one. See `terms.zig` for
/// what the derivation covers and what it deliberately refuses.
pub const QueryOf = query_mod.QueryOf;

/// Sorting and grouping a query's results. `QueryOptions.order_by` and `.group_by` take
/// the descriptors; these build the C callbacks they hold out of ordinary Zig functions.
pub const OrderBy = types.OrderBy;
pub const GroupBy = types.GroupBy;
pub const orderBy = query_mod.orderBy;
pub const orderByEntity = query_mod.orderByEntity;
pub const orderByEntityId = query_mod.orderByEntityId;
pub const groupBy = query_mod.groupBy;

/// The spec markers. A bare handle is a read-write term; these are the rest.
pub const in = terms_mod.in;
pub const out = terms_mod.out;
pub const optional = terms_mod.optional;
pub const without = terms_mod.without;
pub const withId = terms_mod.withId;
pub const withoutId = terms_mod.withoutId;
pub const term = terms_mod.term;
pub const TermOptions = terms_mod.TermOptions;

/// The same markers as types, for writing a spec's type down where a callback's
/// parameter needs it: `const Movers = struct { Component(Position), In(Component(Velocity)) };`
pub const Marked = terms_mod.Marked;
pub const In = terms_mod.In;
pub const Out = terms_mod.Out;
pub const Optional = terms_mod.Optional;
pub const Without = terms_mod.Without;
pub const WithId = terms_mod.WithId;
pub const WithoutId = terms_mod.WithoutId;

/// The derivation itself, for building a system or an observer out of the same spec the
/// callback reads: `SpecOf(@TypeOf(spec)).build(spec)` is the term list, `RowOf` is the
/// callback's parameter type, and `rowCallback` is the thunk between them.
pub const SpecOf = terms_mod.Spec;
pub const RowOf = terms_mod.RowOf;
pub const rowCallback = terms_mod.rowCallback;

pub const SystemDesc = system_mod.SystemDesc;
pub const ObserverDesc = observer_mod.ObserverDesc;

/// Reflection: a flecs schema derived from a Zig type, so the Explorer, the JSON
/// serialiser and the REST API can read a component without a hand-written schema.
/// `zecs.meta.register(world, position)`. Needs the meta addon.
pub const meta = @import("meta.zig");

//=============================================================================
// Strings, serialization and documentation
//
// These stay namespaced rather than being lifted flat like the types above: `toJson`
// and `set` mean nothing without the subject in front of them, and a `zecs.json.` or
// `zecs.doc.` prefix at the call site is what supplies it.
//=============================================================================

/// Adapters between `ecs_strbuf_t` and `std.Io.Writer`, and the owned-string type the
/// serializers hand back.
pub const strbuf = @import("strbuf.zig");

/// JSON serialization and parsing. Needs the `json` addon.
pub const json = @import("json.zig");

/// Documentation strings on entities. Needs the `doc` addon.
pub const doc = @import("doc.zig");

//=============================================================================
// Tables and direct storage
//=============================================================================

pub const Table = table_mod.Table;
pub const Record = table_mod.Record;
pub const Read = table_mod.Read;
pub const Write = table_mod.Write;
pub const readBegin = table_mod.readBegin;
pub const writeBegin = table_mod.writeBegin;
pub const Ref = table_mod.Ref;
pub const ref = table_mod.ref;

//=============================================================================
// Values, and the memory flecs hands back
//=============================================================================

pub const Value = value_mod.Value;
pub const freeString = value_mod.freeString;

//=============================================================================
// Script
//
// Needs the script addon. The declarations are always here; calling one from a build
// without the addon is a compile error naming the option.
//=============================================================================

pub const Script = script_mod.Script;
pub const Vars = script_mod.Vars;
pub const Expr = script_mod.Expr;
pub const evalExpr = script_mod.evalExpr;
pub const Diagnostic = script_mod.Diagnostic;
pub const ParseDesc = script_mod.ParseDesc;
pub const EvalDesc = script_mod.EvalDesc;
pub const RunDesc = script_mod.RunDesc;
pub const LoadDesc = script_mod.LoadDesc;

//=============================================================================
// Scheduling, observability and the app loop
//
// Three namespaces rather than three sets of flat names, because most of what they
// hold is a descriptor plus the one call that takes it, and because the operations
// they add take a world rather than hang off it. Everything in them that the typed
// layer does not cover is reachable as `zecs.c`, and each module says which parts
// those are and why.
//=============================================================================

/// Pipelines, phases and modules. Needs the pipeline and module addons.
pub const pipeline = @import("pipeline.zig");

/// Statistics, metrics and alerts. Needs the stats, metrics and alerts addons.
pub const stats = @import("stats.zig");

/// The app loop and the REST interface. Needs the app and rest addons.
pub const app = @import("app.zig");

//=============================================================================
// Versions
//=============================================================================

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

/// Version of these bindings.
pub const version: Version = .{ .major = 0, .minor = 1, .patch = 0 };

/// Version of the vendored flecs. Checked against `UPSTREAM.md` by the ABI test, and
/// against the compiled header rather than written down twice.
pub const flecs_version: Version = .{ .major = 4, .minor = 1, .patch = 6 };

//=============================================================================
// Tests
//=============================================================================

test {
    // Pull every module in so its own tests are discovered.
    _ = error_mod;
    _ = memory;
    _ = types;
    _ = component_mod;
    _ = iter_mod;
    _ = query_mod;
    _ = terms_mod;
    _ = system_mod;
    _ = observer_mod;
    _ = world_mod;
    _ = meta;
    _ = strbuf;
    _ = json;
    _ = doc;
    _ = table_mod;
    _ = value_mod;
    _ = script_mod;
    _ = pipeline;
    _ = stats;
    _ = app;
    // Only compiled in a test build. It `@cImport`s flecs.h, and keeping that inside
    // a test block is what stops translate-c from reaching the shipped module.
    _ = @import("abi_check.zig");
}
