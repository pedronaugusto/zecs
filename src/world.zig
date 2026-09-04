//! The world: storage, and everything that acts on it.
//!
//! The API is world-centric, the way flecs's C API is: entities are integers, and
//! operations take the world that owns them. The alternative — a handle type carrying
//! both the id and the world — reads more fluently and costs eight bytes on every
//! entity value plus a second way to spell every operation. A host that wants that
//! shape can build it in a few lines on top of this; the reverse is not true.
//!
//! Everything here that touches component data is `inline` and generic over the
//! component's type, so the size passed to flecs is always `@sizeOf(T)` and the pointer
//! that comes back is already typed. None of it survives to runtime as a wrapper.

const std = @import("std");
const c = @import("c/entity.zig");
// `ecs_get_world` maps a stage back to the world behind it, and lives in the
// world module rather than the entity one.
const c_world = @import("c/world.zig");
const types = @import("types.zig");
const os = @import("os.zig");
const component_mod = @import("component.zig");
const iter_mod = @import("iter.zig");
const query_mod = @import("query.zig");
const terms_mod = @import("terms.zig");
const system_mod = @import("system.zig");
// Named `build_options` rather than `options` as elsewhere in the package: the query
// entry points below take a `types.QueryOptions` parameter that is already called that,
// and Zig refuses a parameter that shadows a declaration.
const build_options = @import("zecs_options");
const observer_mod = @import("observer.zig");
const Error = @import("error.zig").Error;

const Entity = types.Entity;
const Id = types.Id;
const Str = types.Str;
const Component = component_mod.Component;
const Query = query_mod.Query;

/// Options for creating an entity.
pub const EntityDesc = struct {
    /// A name, unique within `parent`. Names are optional; most entities have none.
    name: ?[:0]const u8 = null,
    /// Parent entity, added as a `ChildOf` pair.
    parent: Entity = 0,
    /// Reuse a specific id rather than allocating one.
    id: Entity = 0,
    /// Ids to add on creation. Cheaper than adding them one at a time, which moves the
    /// entity between tables once per addition.
    add: []const Id = &.{},
    /// Treat `.` in `name` as a scope separator, creating intermediate entities.
    /// Off by default: names that came from a type or a file path are full of dots and
    /// almost never mean a hierarchy.
    tokenize_name: bool = false,
};

pub const World = struct {
    raw: *c.ecs_world_t,

    //=========================================================================
    // Lifecycle
    //=========================================================================

    /// Creates a world with the addons this build was compiled with.
    ///
    /// Install an allocator first if you want one — see `zecs.setAllocator`. After a
    /// world exists it is too late, and saying so is the whole reason that function
    /// returns an error.
    pub fn init() Error!World {
        const raw = c.ecs_init() orelse return Error.WorldInitFailed;
        os.noteWorldCreated();
        return .{ .raw = raw };
    }

    /// Creates a world with only the core: no builtin modules, no pipeline, no
    /// reflection. Systems will not run from `progress`.
    pub fn initMinimal() Error!World {
        const raw = c.ecs_mini() orelse return Error.WorldInitFailed;
        os.noteWorldCreated();
        return .{ .raw = raw };
    }

    /// Destroys the world and everything in it.
    pub fn deinit(self: World) void {
        _ = c.ecs_fini(self.raw);
        os.noteWorldDestroyed();
    }

    //=========================================================================
    // Frames
    //=========================================================================

    /// Runs one frame of the pipeline: every system in phase order.
    ///
    /// Returns false once `quit` has been called. A `delta_time` of zero asks flecs to
    /// measure the frame itself.
    ///
    /// Needs the pipeline addon: `ecs_progress` is compiled into flecs only with it.
    pub fn progress(self: World, delta_time: c.ecs_ftime_t) bool {
        if (comptime !build_options.addon_pipeline) @compileError(
            "zecs.World.progress needs the pipeline addon: build with -Daddon_pipeline=true",
        );
        return c.ecs_progress(self.raw, delta_time);
    }

    /// Runs one system, outside the pipeline.
    ///
    /// Needs the system addon.
    pub fn run(self: World, target: Entity, delta_time: c.ecs_ftime_t, param: ?*anyopaque) Entity {
        if (comptime !build_options.addon_system) @compileError(
            "zecs.World.run needs the system addon: build with -Daddon_system=true",
        );
        return c.ecs_run(self.raw, target, delta_time, param);
    }

    /// Spreads multi-threaded systems across `threads` worker threads.
    ///
    /// The threads come from flecs's OS API, so this needs the `os_api_impl` addon,
    /// which is in the default set. Systems only use them if they asked to with
    /// `SystemDesc.multi_threaded`.
    ///
    /// If an allocator was installed, it will be called from these threads.
    ///
    /// Needs the pipeline addon too: it is the pipeline that owns the worker threads,
    /// and `ecs_set_threads` is compiled into flecs with it.
    pub fn setThreads(self: World, threads: i32) void {
        if (comptime !build_options.addon_pipeline) @compileError(
            "zecs.World.setThreads needs the pipeline addon: build with -Daddon_pipeline=true",
        );
        c.ecs_set_threads(self.raw, threads);
    }

    /// Like `setThreads`, but the threads only exist while a frame is running.
    ///
    /// Needs the pipeline addon.
    pub fn setTaskThreads(self: World, task_threads: i32) void {
        if (comptime !build_options.addon_pipeline) @compileError(
            "zecs.World.setTaskThreads needs the pipeline addon: build with -Daddon_pipeline=true",
        );
        c.ecs_set_task_threads(self.raw, task_threads);
    }

    pub fn setTargetFps(self: World, fps: c.ecs_ftime_t) void {
        c.ecs_set_target_fps(self.raw, fps);
    }

    pub fn quit(self: World) void {
        c.ecs_quit(self.raw);
    }

    pub fn shouldQuit(self: World) bool {
        return c.ecs_should_quit(self.raw);
    }

    /// One frame, for a host that drives its own main loop instead of calling
    /// `progress`.
    ///
    /// `ecs_frame_begin` is what makes the FPS limiter, the frame timers and
    /// `delta_time` work; skipping it leaves those reading zero. Since it has to be
    /// paired with `ecs_frame_end` and the pairing is what `progress` does internally,
    /// the pair is a scope here rather than two calls to keep straight by hand.
    ///
    /// Both halves need the pipeline addon: the frame is the pipeline's, and flecs
    /// compiles neither function without it.
    pub const Frame = struct {
        world: *c.ecs_world_t,
        /// The delta time flecs will pass to systems: the value handed to `frame`, or
        /// the time flecs measured when that value was zero.
        delta_time: c.ecs_ftime_t,
        open: bool = true,

        /// Ends the frame. Doing it twice is not allowed by flecs, so the second call
        /// is ignored and `defer` is safe on an error path.
        pub fn end(self: *Frame) void {
            if (comptime !build_options.addon_pipeline) @compileError(
                "zecs.World.Frame needs the pipeline addon: build with -Daddon_pipeline=true",
            );
            if (!self.open) return;
            self.open = false;
            c.ecs_frame_end(self.world);
        }
    };

    /// Opens a frame. A `delta_time` of zero asks flecs to measure it.
    ///
    /// Only from the thread that owns the world.
    pub fn frame(self: World, delta_time: c.ecs_ftime_t) Frame {
        if (comptime !build_options.addon_pipeline) @compileError(
            "zecs.World.frame needs the pipeline addon: build with -Daddon_pipeline=true",
        );
        return .{
            .world = self.raw,
            .delta_time = c.ecs_frame_begin(self.raw, delta_time),
        };
    }

    //=========================================================================
    // Deferring, readonly mode and stages
    //
    // Every one of these is a region with a beginning and an end, and flecs's own
    // failure mode for all of them is the same: an end that never runs because the
    // code between the two returned early. Each is therefore a scope value with an
    // idempotent `end`, so `defer scope.end()` is correct on the happy path and on
    // every error return through it.
    //
    // Idempotence is not decoration. flecs counts `defer_begin`/`defer_end` and flushes
    // at zero, so an extra `end` would flush somebody else's queue; `frame_end` and
    // `readonly_end` are worse still. A flag is cheaper than the bug.
    //=========================================================================

    /// Defers structural changes until the matching `deferEnd`. Inside a deferred
    /// block, adds, removes and deletes are recorded and applied at the end, so
    /// iteration is not disturbed by them.
    ///
    /// Returns whether this call is the one that turned deferring on: flecs counts the
    /// calls, so a nested `deferBegin` reports false and its `deferEnd` does not flush.
    pub fn deferBegin(self: World) bool {
        return c.ecs_defer_begin(self.raw);
    }

    pub fn deferEnd(self: World) bool {
        return c.ecs_defer_end(self.raw);
    }

    pub fn isDeferred(self: World) bool {
        return c.ecs_is_deferred(self.raw);
    }

    pub const DeferScope = struct {
        world: *c.ecs_world_t,
        open: bool = true,

        /// Closes the scope, flushing the queue if this was the outermost one.
        pub fn end(self: *DeferScope) void {
            if (!self.open) return;
            self.open = false;
            _ = c.ecs_defer_end(self.world);
        }
    };

    /// Opens a deferred region: `var d = world.deferScope(); defer d.end();`.
    ///
    /// Nesting is fine — flecs counts the scopes and flushes when the outermost one
    /// closes.
    pub fn deferScope(self: World) DeferScope {
        _ = c.ecs_defer_begin(self.raw);
        return .{ .world = self.raw };
    }

    pub const SuspendScope = struct {
        world: *c.ecs_world_t,
        open: bool = true,

        pub fn end(self: *SuspendScope) void {
            if (!self.open) return;
            self.open = false;
            c.ecs_defer_resume(self.world);
        }
    };

    /// Steps outside the command queue without flushing it, so that the operations in
    /// between take effect immediately.
    ///
    /// Only legal while deferring is on, and it has to be closed before the enclosing
    /// `DeferScope` is: flecs asserts on both. It suspends the current stage, so a
    /// suspended stage is still a deferred one as far as `isDeferred` is concerned.
    pub fn suspendScope(self: World) SuspendScope {
        c.ecs_defer_suspend(self.raw);
        return .{ .world = self.raw };
    }

    pub const ReadonlyScope = struct {
        world: *c.ecs_world_t,
        open: bool = true,

        /// Leaves readonly mode and merges every stage's commands into the world.
        pub fn end(self: *ReadonlyScope) void {
            if (!self.open) return;
            self.open = false;
            c.ecs_readonly_end(self.world);
        }
    };

    /// Puts the world in readonly mode: a stronger deferring, where creating systems
    /// and queries is refused as well as mutating entities.
    ///
    /// Writes have to go to a stage while this is open — see `stage`. With
    /// `multi_threaded` set, the concessions flecs makes to single-threaded readonly
    /// mode are withdrawn as well: entity creation, implicit component registration and
    /// building a query on the fly stop being safe from the world itself.
    ///
    /// Both ends of this must run on the thread that owns the world; the calls
    /// themselves are not thread-safe.
    pub fn readonlyScope(self: World, multi_threaded: bool) ReadonlyScope {
        _ = c.ecs_readonly_begin(self.raw, multi_threaded);
        return .{ .world = self.raw };
    }

    /// The stage at `index`, as a world.
    ///
    /// A stage is a private command queue wearing a world pointer, which is what makes
    /// it usable from one worker thread while the world is readonly: every operation
    /// here works on it unchanged, and that is flecs's design rather than an accident.
    /// Set the number of stages first with `zecs.c.world.ecs_set_stage_count`, or let
    /// `setThreads` do it.
    ///
    /// `deinit` is the one operation that does not belong on the result — it would end
    /// the whole world, and flecs asserts rather than doing it.
    ///
    /// The index is checked here against `ecs_get_stage_count`, because flecs checks it
    /// with an assert that a release build removes.
    pub fn stage(self: World, index: i32) Error!World {
        if (index < 0 or index >= c.ecs_get_stage_count(self.raw)) return Error.StageOutOfRange;
        const raw = c.ecs_get_stage(self.raw, index) orelse return Error.StageOutOfRange;
        return .{ .raw = raw };
    }

    //=========================================================================
    // Components
    //=========================================================================

    /// Registers `T` as a component and returns a typed handle to it.
    ///
    /// The handle belongs to this world. Registering the same type twice returns the
    /// same id, so this is safe to call from several places.
    pub fn component(
        self: World,
        comptime T: type,
        desc: component_mod.ComponentDesc,
    ) Error!Component(T) {
        const name = desc.name orelse component_mod.defaultName(T);

        var entity_id = desc.entity;
        if (entity_id == 0) {
            entity_id = c.ecs_entity_init(self.raw, &.{
                .name = name.ptr,
                // Component names come from `@typeName` and are full of dots. An empty
                // separator tells flecs to take the name literally rather than reading
                // it as a path and creating a scope entity per segment.
                //
                // `root_sep` stays null on purpose. flecs tests a name against it with
                // a prefix comparison, and every string starts with the empty string —
                // so an empty root separator makes every name look root-qualified and
                // silently drops the parent scope.
                .sep = "",
                .use_low_id = true,
            });
            if (entity_id == 0) return Error.EntityInitFailed;
        }

        var c_desc = component_mod.describe(T, desc);
        c_desc.entity = entity_id;

        const id = c.ecs_component_init(self.raw, &c_desc);
        if (id == 0) return Error.ComponentInitFailed;

        if (desc.sparse) c.ecs_add_id(self.raw, id, types.Builtin.sparse.id());
        if (desc.can_toggle) c.ecs_add_id(self.raw, id, types.Builtin.can_toggle.id());
        if (desc.singleton) c.ecs_add_id(self.raw, id, types.Builtin.singleton.id());

        // Recorded on the component itself so that `clone` and `isA` can ask at runtime
        // what only the type knows at compile time. Only for the types that need it, so
        // a world full of plain data never creates the marker at all.
        if (comptime !component_mod.duplicable(T)) {
            c.ecs_add_id(self.raw, id, try self.entity(.{ .name = not_duplicable }));
        }

        return .{ .id = id, .world = self.raw };
    }

    /// Installs the lifecycle hooks `typeHooks` derives for the component's Zig type.
    ///
    /// The same hooks can be passed to `component` through `ComponentDesc.hooks`, which
    /// is the better place for them: hooks may only be set while the component has not
    /// been added to anything yet, and registration is the only moment that is
    /// guaranteed to be true of.
    pub inline fn setHooks(self: World, comp: anytype) void {
        const derived = component_mod.typeHooks(@TypeOf(comp).Type);
        c.ecs_set_hooks_id(self.raw, self.idOf(comp), &derived);
    }

    //=========================================================================
    // Entities
    //=========================================================================

    /// Creates an entity with no components.
    pub fn newEntity(self: World) Entity {
        return c.ecs_new(self.raw);
    }

    /// Creates an entity that starts with one id.
    pub fn newWithId(self: World, id: Id) Entity {
        return c.ecs_new_w_id(self.raw, id);
    }

    /// Creates an entity that starts with one component.
    pub fn newWith(self: World, comp: anytype) Entity {
        return c.ecs_new_w_id(self.raw, self.idOf(comp));
    }

    /// Creates an entity from a description: named, parented, or with several ids at
    /// once.
    pub fn entity(self: World, desc: EntityDesc) Error!Entity {
        var add_buffer: [c.FLECS_ID_DESC_MAX]Id = undefined;
        // One slot is reserved for the terminating zero flecs reads the array up to.
        if (desc.add.len >= add_buffer.len) return Error.TooManyIds;
        @memcpy(add_buffer[0..desc.add.len], desc.add);
        add_buffer[desc.add.len] = 0; // flecs reads until a zero id

        const id = c.ecs_entity_init(self.raw, &.{
            .id = desc.id,
            .parent = desc.parent,
            .name = if (desc.name) |n| n.ptr else null,
            // See `component` for why `root_sep` is left alone.
            .sep = if (desc.tokenize_name) null else "",
            // `ecs_entity_desc_t.add` is a zero-terminated array, and the sentinel is in
            // the type — so the slice has to carry it rather than being a bare pointer.
            .add = if (desc.add.len > 0) add_buffer[0..desc.add.len :0].ptr else null,
        });
        if (id == 0) return Error.EntityInitFailed;
        return id;
    }

    /// Creates `n` entities that all start with one id, in one table insertion.
    ///
    /// The returned slice points into flecs's own storage: creating or deleting any
    /// entity invalidates it, and so does an observer that fires from this call. Copy
    /// it before doing either.
    pub inline fn bulkNew(self: World, comp: anytype, n: i32) Error![]const Entity {
        return self.bulkNewId(self.idOf(comp), n);
    }

    /// `bulkNew` for a tag, a pair, or an id built at runtime. A zero id creates
    /// entities with nothing on them.
    pub fn bulkNewId(self: World, id: Id, n: i32) Error![]const Entity {
        if (n <= 0) return &.{};
        const first = c.ecs_bulk_new_w_id(self.raw, id, n) orelse return Error.BulkNewFailed;
        const array: [*]const Entity = @ptrCast(first);
        return array[0..@intCast(n)];
    }

    /// Options for `bulkInit`.
    pub const BulkDesc = struct {
        /// How many entities to create or populate.
        count: i32,
        /// The ids every one of them gets.
        ids: []const Id = &.{},
        /// Ids to use instead of freshly allocated ones. They must not be alive yet;
        /// flecs asserts on any that is. Length must be at least `count`.
        ///
        /// Providing this is also what makes the returned slice stable, since flecs
        /// then has no reason to hand back a pointer into its entity index.
        entities: ?[]Entity = null,
        /// One value column per entry in `ids`, each an array of `count` values of
        /// that component's type. Null for the columns that stay default-constructed,
        /// and null altogether to construct everything.
        ///
        /// This is the one parameter here that stays untyped: the columns have
        /// different types by construction, so there is no Zig type to give the array
        /// as a whole. The lengths, at least, are checked.
        data: ?[]const ?*anyopaque = null,
    };

    /// Creates or populates many entities in one table insertion.
    ///
    /// Much cheaper than the same entities one at a time, which moves each one between
    /// tables once per id. flecs still emits `OnAdd` for every id and `OnSet` for every
    /// column in `data`, so observers see this exactly as they would the slow version.
    ///
    /// flecs does not take ownership of `data`; the values are copied or moved out of
    /// it. The returned slice carries the same warning as `bulkNew` unless `entities`
    /// was supplied.
    pub fn bulkInit(self: World, desc: BulkDesc) Error![]const Entity {
        if (desc.count <= 0) return &.{};
        const n: usize = @intCast(desc.count);

        var ids: [c.FLECS_ID_DESC_MAX]Id = undefined;
        // One slot is reserved for the terminating zero flecs reads the array up to.
        if (desc.ids.len >= ids.len) return Error.TooManyIds;
        @memcpy(ids[0..desc.ids.len], desc.ids);
        ids[desc.ids.len] = 0;

        if (desc.data) |values| {
            if (values.len != desc.ids.len) return Error.BulkArrayMismatch;
        }
        if (desc.entities) |slots| {
            if (slots.len < n) return Error.BulkArrayMismatch;
        }

        const first = c.ecs_bulk_init(self.raw, &.{
            .count = desc.count,
            .ids = ids,
            .entities = if (desc.entities) |slots| @ptrCast(slots.ptr) else null,
            .data = if (desc.data) |values| @ptrCast(@constCast(values.ptr)) else null,
        }) orelse return Error.BulkNewFailed;

        const array: [*]const Entity = @ptrCast(first);
        return array[0..n];
    }

    pub fn delete(self: World, e: Entity) void {
        c.ecs_delete(self.raw, e);
    }

    /// Deletes every entity that has `id`.
    pub fn deleteWith(self: World, id: Id) void {
        c.ecs_delete_with(self.raw, id);
    }

    /// Whether the entity exists and has not been deleted. Recycled ids carry a
    /// generation, so an id from a deleted entity reports false even after its index
    /// has been reused.
    pub fn isAlive(self: World, e: Entity) bool {
        return c.ecs_is_alive(self.raw, e);
    }

    /// Finds an entity by the name it was created with, or 0.
    ///
    /// Taken LITERALLY, dots and all — the same way `entity` and `component` write a
    /// name. `ecs_lookup` reads its argument as a path separated by `.`, so
    /// `lookup(@typeName(T))` through it never found the component `component(T, .{})`
    /// had just registered: one half of the package created `main.Position` as a name
    /// and the other half asked for a `Position` inside a scope called `main`. A name
    /// that really is a path is `lookupPath`, which takes the separator.
    pub fn lookup(self: World, path: [:0]const u8) Entity {
        return c.ecs_lookup_path_w_sep(self.raw, 0, path.ptr, "", null, true);
    }

    pub fn getName(self: World, e: Entity) ?[:0]const u8 {
        const name = c.ecs_get_name(self.raw, e) orelse return null;
        return std.mem.span(name);
    }

    pub fn setName(self: World, e: Entity, name: [:0]const u8) void {
        _ = c.ecs_set_name(self.raw, e, name.ptr);
    }

    pub fn getParent(self: World, e: Entity) Entity {
        return c.ecs_get_parent(self.raw, e);
    }

    /// The `index`th target of a relationship on an entity.
    pub fn getTarget(self: World, e: Entity, relationship: Entity, index: i32) Entity {
        return c.ecs_get_target(self.raw, e, relationship, index);
    }

    //=========================================================================
    // Paths and scopes
    //
    // The separator and prefix that flecs takes as C strings default to the ones the
    // `ecs_*_path` shorthands use, so the common call is the short one and the rest of
    // the knobs are still reachable without dropping to the raw layer.
    //=========================================================================

    /// How a path is spelled: which entity it starts from, and what joins its parts.
    pub const PathDesc = struct {
        /// The entity the path is relative to. Zero for the root.
        from: Entity = 0,
        /// What goes between the names. flecs's own default.
        sep: [:0]const u8 = ".",
        /// Written in front of a path that starts at the root. Null for none, which is
        /// what the `ecs_*_path` shorthands use.
        prefix: ?[:0]const u8 = null,
    };

    /// The path from `desc.from` down to an entity, as an owned string.
    ///
    /// An entity's path to itself is the empty string, and flecs allocates that like
    /// any other — it is a `Str` to free, not a null. Null is what flecs returns when
    /// it wrote nothing at all.
    ///
    /// The result is flecs's memory. Free it with `Str.deinit`, not with the host's
    /// allocator.
    pub fn pathOf(self: World, e: Entity, desc: PathDesc) ?Str {
        return Str.take(c.ecs_get_path_w_sep(
            self.raw,
            desc.from,
            e,
            desc.sep.ptr,
            if (desc.prefix) |p| p.ptr else null,
        ));
    }

    /// How a path is resolved.
    pub const LookupDesc = struct {
        /// The entity to resolve the path against. Zero for the root, or for the
        /// current scope when one is set.
        from: Entity = 0,
        sep: [:0]const u8 = ".",
        prefix: ?[:0]const u8 = null,
        /// Keep looking in `from`'s ancestors when the name is not found there, and
        /// then in `flecs.core`. flecs's own lookup does this.
        recursive: bool = true,
    };

    /// Resolves a path, returning 0 when nothing answers to it — the same shape as
    /// `lookup`, which is this with everything defaulted.
    pub fn lookupPath(self: World, full_path: [:0]const u8, desc: LookupDesc) Entity {
        return c.ecs_lookup_path_w_sep(
            self.raw,
            desc.from,
            full_path.ptr,
            desc.sep.ptr,
            if (desc.prefix) |pre| pre.ptr else null,
            desc.recursive,
        );
    }

    /// Finds or creates the entity at a path, creating the entities along the way.
    ///
    /// Unlike `lookupPath` this does not search upwards: the path is taken literally
    /// under `desc.from`, which is what makes creating one meaningful.
    pub fn newFromPath(self: World, full_path: [:0]const u8, desc: PathDesc) Error!Entity {
        const id = c.ecs_new_from_path_w_sep(
            self.raw,
            desc.from,
            full_path.ptr,
            desc.sep.ptr,
            if (desc.prefix) |pre| pre.ptr else null,
        );
        if (id == 0) return Error.EntityInitFailed;
        return id;
    }

    pub const Scope = struct {
        world: *c.ecs_world_t,
        previous: Entity,
        open: bool = true,

        /// Restores the scope that was in force when this one was opened.
        pub fn end(self: *Scope) void {
            if (!self.open) return;
            self.open = false;
            _ = c.ecs_set_scope(self.world, self.previous);
        }
    };

    /// Makes `parent` the scope: new entities are created under it, and lookups are
    /// relative to it, until the returned value's `end` runs.
    ///
    /// flecs's own `ecs_set_scope` hands back the previous scope and leaves restoring
    /// it to the caller, which is the part that gets skipped on an early return. The
    /// scope is per stage, so this affects the stage it was called on and no other.
    pub fn scope(self: World, parent: Entity) Scope {
        return .{ .world = self.raw, .previous = c.ecs_set_scope(self.raw, parent) };
    }

    //=========================================================================
    // What an entity is made of
    //=========================================================================

    /// Every id on an entity, in the order the table stores them. Empty when the
    /// entity has nothing on it.
    ///
    /// The slice is the table's own type array. Anything that moves the entity between
    /// tables invalidates it, and so does deleting the entity.
    pub fn typeOf(self: World, e: Entity) []const Id {
        const t = c.ecs_get_type(self.raw, e) orelse return &.{};
        const array = t.array orelse return &.{};
        if (t.count <= 0) return &.{};
        const ids: [*]const Id = @ptrCast(array);
        return ids[0..@intCast(t.count)];
    }

    /// An entity's ids as flecs renders them, `"Position, Velocity, (ChildOf,parent)"`.
    /// Null when there is nothing to render, which for an entity with no components is
    /// what happens. Owned; see `Str`.
    pub fn typeStr(self: World, e: Entity) ?Str {
        return Str.take(c.ecs_type_str(self.raw, c.ecs_get_type(self.raw, e) orelse return null));
    }

    /// One id as flecs renders it: `"Position"`, `"(ChildOf,parent)"`, or a flag and
    /// one of those. Owned; see `Str`.
    pub fn idStr(self: World, id: Id) ?Str {
        return Str.take(c.ecs_id_str(self.raw, id));
    }

    /// Walks the children of an entity.
    ///
    /// Not quite `each` over `(ChildOf, parent)`: when the parent keeps its children in
    /// order, this returns them in that order, in a single result.
    pub const ChildIterator = iter_mod.Iterator(&c.ecs_children_next);

    pub fn children(self: World, parent: Entity) ChildIterator {
        return .{ .raw = c.ecs_children(self.raw, parent) };
    }

    /// The id a handle carries, checked against this world.
    ///
    /// Component ids are per-world and are handed out in registration order, so the
    /// same number means different things in two worlds — see the head of
    /// `src/component.zig` for what that costs. Comparing the worlds is one load and
    /// one branch, and `std.debug.assert` removes it in ReleaseFast, where a host that
    /// has already run the same code in a checked build is paying for nothing.
    ///
    /// `ecs_get_world` rather than the pointers themselves: a system runs against a
    /// stage, which is a different pointer for the same world, and a handle registered
    /// on the world is legitimately used from one.
    inline fn idOf(self: World, handle: anytype) Id {
        std.debug.assert(self.minted(handle));
        return handle.asId();
    }

    /// Whether this world is the one that minted `handle`.
    ///
    /// Not `owns`: that name is flecs's, for whether an entity has a component of its
    /// own rather than inheriting one, and it is taken.
    ///
    /// Separate from the assertion that uses it for the same reason `isStorable` is
    /// separate from the refusal built on it: an assertion cannot be caught, so from
    /// inside the language a check wired up wrongly and a check that never fires are
    /// the same thing. The tests drive this on handles from two worlds.
    ///
    /// True for a handle that remembers no world — a pair, or one of flecs's global
    /// component ids. There is nothing to compare it against, which is not the same as
    /// a mismatch.
    ///
    /// `ecs_get_world` rather than the pointers themselves: a system runs against a
    /// stage, which is a different pointer for the same world, and a handle registered
    /// on the world is legitimately used from one.
    pub inline fn minted(self: World, handle: anytype) bool {
        if (comptime !@hasField(@TypeOf(handle), "world")) return true;
        const owner = handle.world orelse return true;
        return c_world.ecs_get_world(@ptrCast(self.raw)) ==
            c_world.ecs_get_world(@ptrCast(owner));
    }

    //=========================================================================
    // Components on entities
    //
    // Each operation comes in two forms: a typed one taking a `Component(T)`, and an
    // `*Id` one taking a raw id for tags, pairs and anything built at runtime.
    //=========================================================================

    pub inline fn add(self: World, e: Entity, comp: anytype) void {
        c.ecs_add_id(self.raw, e, self.idOf(comp));
    }

    pub inline fn addId(self: World, e: Entity, id: Id) void {
        c.ecs_add_id(self.raw, e, id);
    }

    /// Adds a relationship pair, such as `(ChildOf, parent)`.
    pub inline fn addPair(self: World, e: Entity, first: Entity, second: Entity) void {
        c.ecs_add_id(self.raw, e, types.pair(first, second));
    }

    pub inline fn remove(self: World, e: Entity, comp: anytype) void {
        c.ecs_remove_id(self.raw, e, self.idOf(comp));
    }

    pub inline fn removeId(self: World, e: Entity, id: Id) void {
        c.ecs_remove_id(self.raw, e, id);
    }

    /// Sets a component's value, adding it if the entity did not have it.
    ///
    /// A zero-sized component is a tag: there is nothing to store, so this adds it.
    pub inline fn set(self: World, e: Entity, comp: anytype, value: @TypeOf(comp).Type) void {
        const T = @TypeOf(comp).Type;
        if (@sizeOf(T) == 0) {
            c.ecs_add_id(self.raw, e, self.idOf(comp));
            return;
        }
        var local = value;
        c.ecs_set_id(self.raw, e, self.idOf(comp), @sizeOf(T), &local);
    }

    pub inline fn setId(self: World, e: Entity, id: Id, size: usize, ptr: ?*const anyopaque) void {
        c.ecs_set_id(self.raw, e, id, size, ptr);
    }

    /// Reads a component. Null when the entity does not have it.
    ///
    /// The pointer is into flecs's storage and is invalidated by anything that moves
    /// the entity between tables — adding or removing a component, deleting another
    /// entity in the same table. Read it, use it, do not keep it.
    pub inline fn get(self: World, e: Entity, comp: anytype) ?*const @TypeOf(comp).Type {
        const ptr = c.ecs_get_id(self.raw, e, self.idOf(comp)) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Reads a component for modification. Null when the entity does not have it.
    ///
    /// Changing the value through this pointer does not notify observers watching for
    /// `OnSet`; call `modified` when you are done if anything is listening.
    pub inline fn getMut(self: World, e: Entity, comp: anytype) ?*@TypeOf(comp).Type {
        const ptr = c.ecs_get_mut_id(self.raw, e, self.idOf(comp)) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Reads a component, adding it first if the entity does not have it. Never null
    /// for a component with data.
    pub inline fn ensure(self: World, e: Entity, comp: anytype) *@TypeOf(comp).Type {
        const T = @TypeOf(comp).Type;
        const ptr = c.ecs_ensure_id(self.raw, e, self.idOf(comp), @sizeOf(T)).?;
        return @ptrCast(@alignCast(ptr));
    }

    /// Adds a component without constructing it, so the caller can build the value in
    /// place — the move `ensure` cannot express for a type that is expensive to
    /// default-construct, or has no meaningful default at all.
    ///
    /// `is_new` is how the caller learns what it is holding, and it is not advisory.
    /// When it comes back true the storage is uninitialised: the component's
    /// constructor did NOT run, the bytes are whatever the table last had there, and
    /// the caller must write a whole value before anything else — an observer, a
    /// destructor, the next `get` — can see it. When it comes back false the entity
    /// already had the component and the pointer is the existing value.
    ///
    /// Passing null asks flecs to assert that the component is new rather than to
    /// report it, so null is for the case where the caller already knows.
    pub inline fn emplace(
        self: World,
        e: Entity,
        comp: anytype,
        is_new: ?*bool,
    ) *@TypeOf(comp).Type {
        const T = @TypeOf(comp).Type;
        const ptr = c.ecs_emplace_id(self.raw, e, self.idOf(comp), @sizeOf(T), is_new).?;
        return @ptrCast(@alignCast(ptr));
    }

    pub inline fn emplaceId(
        self: World,
        e: Entity,
        id: Id,
        size: usize,
        is_new: ?*bool,
    ) ?*anyopaque {
        return c.ecs_emplace_id(self.raw, e, id, size, is_new);
    }

    /// Announces that a component was changed through `getMut` or `ensure`, so that
    /// `OnSet` observers run.
    pub inline fn modified(self: World, e: Entity, comp: anytype) void {
        c.ecs_modified_id(self.raw, e, self.idOf(comp));
    }

    pub inline fn has(self: World, e: Entity, comp: anytype) bool {
        return c.ecs_has_id(self.raw, e, self.idOf(comp));
    }

    pub inline fn hasId(self: World, e: Entity, id: Id) bool {
        return c.ecs_has_id(self.raw, e, id);
    }

    /// Whether the entity has the component itself, rather than inheriting it from a
    /// prefab or a parent.
    pub inline fn owns(self: World, e: Entity, comp: anytype) bool {
        return c.ecs_owns_id(self.raw, e, self.idOf(comp));
    }

    /// How many entities hold this component.
    ///
    /// A walk of every matching table, not a counter flecs keeps, so this is a
    /// measurement rather than a lookup: fine for a check or a report, wrong in a loop.
    pub inline fn count(self: World, comp: anytype) i32 {
        return c.ecs_count_id(self.raw, self.idOf(comp));
    }

    pub inline fn countId(self: World, id: Id) i32 {
        return c.ecs_count_id(self.raw, id);
    }

    //=========================================================================
    // Switching things off without taking them away
    //
    // Two different mechanisms that share a word. An entity is disabled by giving it
    // the `Disabled` tag, which no query matches unless it asks for it. A COMPONENT is
    // disabled through a bitset the table keeps for it, which is why the component has
    // to have been registered `.can_toggle = true` — flecs refuses the operation
    // otherwise rather than silently doing nothing.
    //
    // Neither removes anything: the value is still there and comes back unchanged.
    //=========================================================================

    /// Enables or disables the entity, by adding or removing flecs's `Disabled` tag.
    ///
    /// A disabled entity is matched by no query and run by no system, unless the query
    /// names `Disabled` itself. Moving it between tables, so it is not free on many
    /// entities every frame.
    ///
    /// The exclusion is a term the query builder adds, so it belongs to queries and not
    /// to the store: `each`, which walks a component's tables directly rather than
    /// compiling a query, still visits a disabled entity. The tests measure both.
    pub inline fn enable(self: World, e: Entity, enabled: bool) void {
        c.ecs_enable(self.raw, e, enabled);
    }

    /// Enables or disables one component on one entity, leaving its value in place.
    ///
    /// Cheaper than adding and removing the component, because it is a bit rather than
    /// a table move — which is the reason to reach for it. Requires the component to
    /// have been registered with `.can_toggle = true`.
    pub inline fn enableComponent(self: World, e: Entity, comp: anytype, enabled: bool) void {
        c.ecs_enable_id(self.raw, e, self.idOf(comp), enabled);
    }

    pub inline fn enableComponentId(self: World, e: Entity, id: Id, enabled: bool) void {
        c.ecs_enable_id(self.raw, e, id, enabled);
    }

    /// Whether the entity has the component AND it has not been switched off.
    ///
    /// False for an entity that does not have the component at all, so this is not the
    /// negation of "disabled" — it is `has` and enabled together.
    pub inline fn isEnabled(self: World, e: Entity, comp: anytype) bool {
        return c.ecs_is_enabled_id(self.raw, e, self.idOf(comp));
    }

    pub inline fn isEnabledId(self: World, e: Entity, id: Id) bool {
        return c.ecs_is_enabled_id(self.raw, e, id);
    }

    //=========================================================================
    // Singletons
    //
    // flecs stores a singleton as an ordinary component on the component's own entity,
    // and its C API spells that as a macro per operation (`ecs_singleton_get` and the
    // rest, flecs.h:12038-12071). Zig has no macros, and `world.get(pos.id, pos)` is
    // the kind of line that reads as a mistake, so the pattern is named here instead.
    //
    // Nothing about the storage is special — `.singleton = true` at registration is
    // what makes a query term for the component resolve to this one value.
    //=========================================================================

    pub inline fn singletonAdd(self: World, comp: anytype) void {
        self.add(comp.id, comp);
    }

    pub inline fn singletonRemove(self: World, comp: anytype) void {
        self.remove(comp.id, comp);
    }

    pub inline fn singletonHas(self: World, comp: anytype) bool {
        return self.has(comp.id, comp);
    }

    pub inline fn singletonGet(self: World, comp: anytype) ?*const @TypeOf(comp).Type {
        return self.get(comp.id, comp);
    }

    pub inline fn singletonGetMut(self: World, comp: anytype) ?*@TypeOf(comp).Type {
        return self.getMut(comp.id, comp);
    }

    pub inline fn singletonSet(self: World, comp: anytype, value: @TypeOf(comp).Type) void {
        self.set(comp.id, comp, value);
    }

    pub inline fn singletonEnsure(self: World, comp: anytype) *@TypeOf(comp).Type {
        return self.ensure(comp.id, comp);
    }

    pub inline fn singletonEmplace(self: World, comp: anytype, is_new: ?*bool) *@TypeOf(comp).Type {
        return self.emplace(comp.id, comp, is_new);
    }

    pub inline fn singletonModified(self: World, comp: anytype) void {
        self.modified(comp.id, comp);
    }

    //=========================================================================
    // Duplication
    //
    // flecs copies a component from one entity into another in two places: `ecs_clone`,
    // and the override an instance gets when it is made an instance of a prefab. For
    // plain data that is a memcpy and it is right. For a component that owns an
    // allocation and has not said how to copy it, it is two owners of one block — and
    // the second free is a crash somewhere else, at a time with nothing to do with the
    // clone.
    //
    // `component.duplicable` settles the question at compile time, from the type.
    // Registration records the answer on the component entity, which is what lets the
    // two operations below ask it at the moment they would otherwise get it wrong.
    //=========================================================================

    /// The tag `component` puts on a component whose values cannot be duplicated.
    ///
    /// An ordinary named entity, so the marking is visible in `typeStr` and in the
    /// Explorer alongside everything else flecs knows about the component, rather than
    /// living in a side table this package would have to keep in step.
    pub const not_duplicable = "zecs.NotDuplicable";

    /// The marker entity for this world. Zero when nothing in this world has ever needed
    /// it, which is the common case and is why every check starts by asking.
    fn notDuplicableTag(self: World) Entity {
        return self.lookup(not_duplicable);
    }

    /// The first component of `e` that cannot be duplicated, or zero. `overrides_only`
    /// restricts the walk to the components an INSTANCE would be given a copy of:
    /// flecs's default for a component is `(OnInstantiate, Override)`, and one marked
    /// `Inherit` or `DontInherit` is never copied, so it cannot double-own.
    fn firstNotDuplicable(self: World, e: Entity, overrides_only: bool) Entity {
        const tag = self.notDuplicableTag();
        if (tag == 0) return 0;
        const on_instantiate = types.Builtin.on_instantiate.id();
        for (self.typeOf(e)) |id| {
            const component_id = c.ecs_get_typeid(self.raw, id);
            if (component_id == 0) continue;
            if (!c.ecs_has_id(self.raw, component_id, tag)) continue;
            if (overrides_only) {
                const trait = c.ecs_get_target(self.raw, component_id, on_instantiate, 0);
                if (trait == types.Builtin.inherit.id()) continue;
                if (trait == types.Builtin.dont_inherit.id()) continue;
            }
            return component_id;
        }
        return 0;
    }

    /// Copies an entity, with its components.
    ///
    /// `copy_value` false gives the destination the same component SET with freshly
    /// constructed values. True copies the values, which is the operation a component
    /// with a `deinit` and no `dupe` cannot survive — so it is refused with
    /// `Error.ComponentNotDuplicable` instead of performed. `notDuplicable` names the
    /// component that caused the refusal.
    ///
    /// `dst` zero creates the destination entity.
    pub fn clone(self: World, dst: Entity, src: Entity, copy_value: bool) Error!Entity {
        if (copy_value and self.firstNotDuplicable(src, false) != 0) {
            return Error.ComponentNotDuplicable;
        }
        const made = c.ecs_clone(self.raw, dst, src, copy_value);
        if (made == 0) return Error.EntityInitFailed;
        return made;
    }

    /// Makes `e` an instance of `base`: it inherits `base`'s components, and is given
    /// its own copy of the ones `base` marks for overriding — which is every component
    /// by default.
    ///
    /// The typed spelling of `add(e, pairOf(Builtin.is_a, base))`, and the place the
    /// duplication question is asked before flecs answers it wrongly. Refuses with
    /// `Error.ComponentNotDuplicable` when the base carries a component that would be
    /// copied and cannot be.
    pub fn isA(self: World, e: Entity, base: Entity) Error!void {
        if (self.firstNotDuplicable(base, true) != 0) return Error.ComponentNotDuplicable;
        c.ecs_add_id(self.raw, e, types.pair(types.Builtin.is_a.id(), base));
    }

    /// The first component of `e` that cannot be duplicated, or zero — the component
    /// `clone` refused over, and the answer to "why did that fail".
    pub fn notDuplicable(self: World, e: Entity) Entity {
        return self.firstNotDuplicable(e, false);
    }

    /// Creates a prefab: an entity flecs leaves out of every query, kept to be
    /// instantiated with `isA`.
    pub fn prefab(self: World, name: ?[:0]const u8) Error!Entity {
        const e = try self.entity(.{ .name = name });
        c.ecs_add_id(self.raw, e, types.Builtin.prefab.id());
        return e;
    }

    /// Marks a component so that an instance of a prefab carrying it gets its OWN copy
    /// rather than reading the prefab's — flecs's `(OnInstantiate, Override)`, which is
    /// already the default, so this is for undoing `inheritOnInstantiate`.
    pub fn overrideOnInstantiate(self: World, comp: anytype) Error!void {
        return self.setOnInstantiate(comp, types.Builtin.override.id());
    }

    /// Marks a component so that instances SHARE the prefab's value rather than copying
    /// it. One value behind however many instances, and a term matching it resolves
    /// through `Up` — which is why `Iter.field` sizes such a field to one element.
    ///
    /// Also the way to put an uncopyable component on a prefab: an inherited component
    /// is never duplicated, so `isA` allows it.
    pub fn inheritOnInstantiate(self: World, comp: anytype) Error!void {
        return self.setOnInstantiate(comp, types.Builtin.inherit.id());
    }

    /// Marks a component so that instances neither copy nor see it.
    pub fn dontInheritOnInstantiate(self: World, comp: anytype) Error!void {
        return self.setOnInstantiate(comp, types.Builtin.dont_inherit.id());
    }

    /// Sets the `(OnInstantiate, *)` trait, which flecs will only accept before the
    /// component has been used.
    ///
    /// flecs caches the trait as a flag on the component's record the first time the
    /// component is added to anything, and ABORTS on a later change
    /// [read-from-source: `flecs_register_flag_for_trait`, `libs/flecs/flecs.c:4178`-`4187`].
    /// The same two questions it asks are asked here first, so a caller gets
    /// `Error.ComponentInUse` where flecs would have taken the process down.
    fn setOnInstantiate(self: World, comp: anytype, trait: Entity) Error!void {
        const id = self.idOf(comp);
        const wildcard = types.Builtin.wildcard.id();
        if (c.ecs_id_in_use(self.raw, id) or
            c.ecs_id_in_use(self.raw, types.pair(id, wildcard)))
        {
            return Error.ComponentInUse;
        }
        // `OnInstantiate` is exclusive, so flecs replaces the existing target rather
        // than leaving two.
        c.ecs_add_id(
            self.raw,
            id,
            types.pair(types.Builtin.on_instantiate.id(), trait),
        );
    }

    //=========================================================================
    // Queries, systems, observers
    //=========================================================================

    pub fn query(self: World, desc: types.QueryDesc) Error!Query {
        var c_desc = try desc.toC();
        const raw = c.ecs_query_init(self.raw, &c_desc) orelse return Error.QueryInitFailed;
        return .{ .raw = raw, .world = self.raw };
    }

    /// A query whose terms come from a tuple of component handles, and whose results come
    /// back as typed slices in the same order.
    ///
    /// ```zig
    /// const q = try world.queryOf(.{ position, zecs.in(velocity) }, .{});
    /// defer q.deinit();
    ///
    /// var it = q.iter();
    /// defer it.deinit();
    /// while (it.next()) |row| {
    ///     const p, const v = row.fields;
    ///     for (p, v) |*pos, vel| pos.x += vel.x * row.deltaTime();
    /// }
    /// ```
    ///
    /// The second argument is `QueryOptions` rather than `QueryDesc` because the terms
    /// come from the spec: there is no second place to put them, so there is nothing for
    /// the two to disagree about. `World.query` remains the way to build a query with
    /// traversal, query variables or an `Or` chain, which the derivation cannot type.
    pub fn queryOf(
        self: World,
        spec: anytype,
        options: types.QueryOptions,
    ) Error!query_mod.QueryOf(@TypeOf(spec)) {
        const S = terms_mod.Spec(@TypeOf(spec));
        const built = S.build(spec);
        const q = try self.query(.{ .terms = &built, .options = options });
        // The derivation assumes one field per term, in order. flecs is the authority on
        // that, so it is asked rather than trusted — at the one point where a query first
        // exists to ask.
        std.debug.assert(S.checkLayout(q.raw));
        return .{ .query = q };
    }

    /// Iterates every entity with one id, with no query to compile first. The cheapest
    /// way to walk a single component.
    pub const EachIterator = iter_mod.Iterator(&c.ecs_each_next);

    pub fn each(self: World, comp: anytype) EachIterator {
        return .{ .raw = c.ecs_each_id(self.raw, self.idOf(comp)) };
    }

    pub fn eachId(self: World, id: Id) EachIterator {
        return .{ .raw = c.ecs_each_id(self.raw, id) };
    }

    /// Creates a system.
    ///
    /// Needs the system addon: `ecs_system_init` is compiled into flecs only with it.
    pub fn system(self: World, desc: system_mod.SystemDesc) Error!Entity {
        if (comptime !build_options.addon_system) @compileError(
            "zecs.World.system needs the system addon: build with -Daddon_system=true",
        );

        // The descriptor is validated before the entity is created, so a rejected
        // descriptor does not leave a stray named entity in the world.
        var c_desc = try desc.toC(0);
        c_desc.entity = try self.namedEntityFor(desc.name);
        const id = c.ecs_system_init(self.raw, &c_desc);
        if (id == 0) return Error.SystemInitFailed;
        return id;
    }

    pub fn observer(self: World, desc: observer_mod.ObserverDesc) Error!Entity {
        var c_desc = try desc.toC(0);
        c_desc.entity = try self.namedEntityFor(desc.name);
        const id = c.ecs_observer_init(self.raw, &c_desc);
        if (id == 0) return Error.ObserverInitFailed;
        return id;
    }

    /// Systems and observers are entities, and naming them is what makes a pipeline
    /// legible in a debugger or an inspector. Same literal-name rule as components.
    fn namedEntityFor(self: World, name: ?[:0]const u8) Error!Entity {
        const chosen = name orelse return 0;
        const id = c.ecs_entity_init(self.raw, &.{
            .name = chosen.ptr,
            .sep = "",
        });
        if (id == 0) return Error.EntityInitFailed;
        return id;
    }

    //=========================================================================
    // Exclusive access
    //=========================================================================

    pub const ExclusiveAccess = struct {
        world: *c.ecs_world_t,
        open: bool = true,

        /// Gives the world back to every thread.
        pub fn end(self: *ExclusiveAccess) void {
            self.release(false);
        }

        /// Gives the world up but leaves it locked: until some thread calls
        /// `exclusiveAccess` again, only reads are allowed from anywhere. Unlock a
        /// world in that state by opening and ending another scope with `end`.
        pub fn endLocked(self: *ExclusiveAccess) void {
            self.release(true);
        }

        fn release(self: *ExclusiveAccess, lock_world: bool) void {
            if (!self.open) return;
            self.open = false;
            c.ecs_exclusive_access_end(self.world, lock_world);
        }
    };

    /// Claims the world for the calling thread: every other thread that touches it
    /// panics until the scope ends.
    ///
    /// flecs does not copy `thread_name` — it keeps the pointer for its own messages —
    /// so the string has to outlive the scope. A literal always does.
    ///
    /// This is a debugging tool, not a lock. The checks it arms are asserts, so a build
    /// with flecs's checks off arms nothing, and it needs the OS API's `thread_self`
    /// callback, which the `os_api_impl` addon supplies. It is not gated on
    /// `options.addon_exclusive_access`: the two entry points are compiled
    /// unconditionally, and it is the checks inside the other operations that the addon
    /// switches on — flecs also turns it on by itself in any `FLECS_DEBUG` build.
    pub fn exclusiveAccess(self: World, thread_name: [:0]const u8) ExclusiveAccess {
        c.ecs_exclusive_access_begin(self.raw, thread_name.ptr);
        return .{ .world = self.raw };
    }
};

//=============================================================================
// Typed pairs
//
// The untyped pair vocabulary — `pair`, `pairFirst`, `isPair` — lives in `types.zig`
// with the rest of the id arithmetic. This one is here instead because it produces a
// `Component(T)`, and `component.zig` already imports `types.zig`: putting it there
// would make the two modules import each other for the sake of one function that takes
// no world and belongs to neither.
//=============================================================================

/// The pair `(first, second)` as a typed component handle.
///
/// Either side may be a `Component(T)` or a plain entity, and the handle carries the
/// type of whichever one flecs stores the pair's value under. That rule is flecs's, not
/// this package's: the first element wins when it is a component with data, otherwise
/// the second, otherwise the pair holds nothing and is a tag. `ecs_get_typeid` answers
/// the same question at runtime, and the two agree.
///
/// The point is that the result goes straight into `set`, `get`, `ensure` and the rest
/// with no size and no cast:
///
/// ```zig
/// world.set(e, zecs.pairOf(damage, fire), .{ .amount = 3 });
/// ```
pub inline fn pairOf(first: anytype, second: anytype) Component(PairValue(@TypeOf(first), @TypeOf(second))) {
    return .{
        .id = types.pair(pairElement(first), pairElement(second)),
        // A pair's id is a function of its halves rather than a registration, so there
        // is no world that minted it. Whichever half was registered says which world
        // the pair is about, and a pair of two bare entity ids says nothing at all.
        .world = pairWorld(first) orelse pairWorld(second),
    };
}

/// The world a pair operand was registered in, if it is a handle that remembers one.
inline fn pairWorld(value: anytype) ?*const c.ecs_world_t {
    if (comptime !isComponentHandle(@TypeOf(value))) return null;
    return value.world;
}

/// The type a `(First, Second)` pair stores, by flecs's rule.
///
/// The one case this cannot see is a relationship marked with flecs's `PairIsTag`
/// trait, which makes a pair hold nothing even though its target is a component. That
/// is a runtime fact about an entity, so a pair built on such a relationship reports a
/// value type here and none from `ecs_get_typeid`.
pub fn PairValue(comptime First: type, comptime Second: type) type {
    if (isComponentHandle(First) and @sizeOf(First.Type) != 0) return First.Type;
    if (isComponentHandle(Second) and @sizeOf(Second.Type) != 0) return Second.Type;
    return void;
}

inline fn pairElement(value: anytype) Entity {
    return if (comptime isComponentHandle(@TypeOf(value))) value.asId() else @as(Entity, value);
}

fn isComponentHandle(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "Type") and @hasDecl(T, "asId"),
        else => false,
    };
}
