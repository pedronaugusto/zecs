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
const types = @import("types.zig");
const memory = @import("memory.zig");
const component_mod = @import("component.zig");
const iter_mod = @import("iter.zig");
const query_mod = @import("query.zig");
const terms_mod = @import("terms.zig");
const system_mod = @import("system.zig");
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
        memory.noteWorldCreated();
        return .{ .raw = raw };
    }

    /// Creates a world with only the core: no builtin modules, no pipeline, no
    /// reflection. Systems will not run from `progress`.
    pub fn initMinimal() Error!World {
        const raw = c.ecs_mini() orelse return Error.WorldInitFailed;
        memory.noteWorldCreated();
        return .{ .raw = raw };
    }

    /// Destroys the world and everything in it.
    pub fn deinit(self: World) void {
        _ = c.ecs_fini(self.raw);
        memory.noteWorldDestroyed();
    }

    //=========================================================================
    // Frames
    //=========================================================================

    /// Runs one frame of the pipeline: every system in phase order.
    ///
    /// Returns false once `quit` has been called. A `delta_time` of zero asks flecs to
    /// measure the frame itself.
    pub fn progress(self: World, delta_time: c.ecs_ftime_t) bool {
        return c.ecs_progress(self.raw, delta_time);
    }

    /// Runs one system, outside the pipeline.
    pub fn run(self: World, target: Entity, delta_time: c.ecs_ftime_t, param: ?*anyopaque) Entity {
        return c.ecs_run(self.raw, target, delta_time, param);
    }

    /// Spreads multi-threaded systems across `count` worker threads.
    ///
    /// The threads come from flecs's OS API, so this needs the `os_api_impl` addon,
    /// which is in the default set. Systems only use them if they asked to with
    /// `SystemDesc.multi_threaded`.
    ///
    /// If an allocator was installed, it will be called from these threads.
    pub fn setThreads(self: World, count: i32) void {
        c.ecs_set_threads(self.raw, count);
    }

    /// Like `setThreads`, but the threads only exist while a frame is running.
    pub fn setTaskThreads(self: World, count: i32) void {
        c.ecs_set_task_threads(self.raw, count);
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
    pub const Frame = struct {
        world: *c.ecs_world_t,
        /// The delta time flecs will pass to systems: the value handed to `frame`, or
        /// the time flecs measured when that value was zero.
        delta_time: c.ecs_ftime_t,
        open: bool = true,

        /// Ends the frame. Doing it twice is not allowed by flecs, so the second call
        /// is ignored and `defer` is safe on an error path.
        pub fn end(self: *Frame) void {
            if (!self.open) return;
            self.open = false;
            c.ecs_frame_end(self.world);
        }
    };

    /// Opens a frame. A `delta_time` of zero asks flecs to measure it.
    ///
    /// Only from the thread that owns the world.
    pub fn frame(self: World, delta_time: c.ecs_ftime_t) Frame {
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

        return .{ .id = id };
    }

    /// Installs the lifecycle hooks `typeHooks` derives for the component's Zig type.
    ///
    /// The same hooks can be passed to `component` through `ComponentDesc.hooks`, which
    /// is the better place for them: hooks may only be set while the component has not
    /// been added to anything yet, and registration is the only moment that is
    /// guaranteed to be true of.
    pub inline fn setHooks(self: World, comp: anytype) void {
        const derived = typeHooks(@TypeOf(comp).Type);
        c.ecs_set_hooks_id(self.raw, comp.asId(), &derived);
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
        return c.ecs_new_w_id(self.raw, comp.asId());
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

    /// Creates `count` entities that all start with one id, in one table insertion.
    ///
    /// The returned slice points into flecs's own storage: creating or deleting any
    /// entity invalidates it, and so does an observer that fires from this call. Copy
    /// it before doing either.
    pub inline fn bulkNew(self: World, comp: anytype, count: i32) Error![]const Entity {
        return self.bulkNewId(comp.asId(), count);
    }

    /// `bulkNew` for a tag, a pair, or an id built at runtime. A zero id creates
    /// entities with nothing on them.
    pub fn bulkNewId(self: World, id: Id, count: i32) Error![]const Entity {
        if (count <= 0) return &.{};
        const first = c.ecs_bulk_new_w_id(self.raw, id, count) orelse return Error.BulkNewFailed;
        const array: [*]const Entity = @ptrCast(first);
        return array[0..@intCast(count)];
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
        const count: usize = @intCast(desc.count);

        var ids: [c.FLECS_ID_DESC_MAX]Id = undefined;
        // One slot is reserved for the terminating zero flecs reads the array up to.
        if (desc.ids.len >= ids.len) return Error.TooManyIds;
        @memcpy(ids[0..desc.ids.len], desc.ids);
        ids[desc.ids.len] = 0;

        if (desc.data) |values| {
            if (values.len != desc.ids.len) return Error.BulkArrayMismatch;
        }
        if (desc.entities) |slots| {
            if (slots.len < count) return Error.BulkArrayMismatch;
        }

        const first = c.ecs_bulk_init(self.raw, &.{
            .count = desc.count,
            .ids = ids,
            .entities = if (desc.entities) |slots| @ptrCast(slots.ptr) else null,
            .data = if (desc.data) |values| @ptrCast(@constCast(values.ptr)) else null,
        }) orelse return Error.BulkNewFailed;

        const array: [*]const Entity = @ptrCast(first);
        return array[0..count];
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

    pub fn lookup(self: World, path: [:0]const u8) Entity {
        return c.ecs_lookup(self.raw, path.ptr);
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

    //=========================================================================
    // Components on entities
    //
    // Each operation comes in two forms: a typed one taking a `Component(T)`, and an
    // `*Id` one taking a raw id for tags, pairs and anything built at runtime.
    //=========================================================================

    pub inline fn add(self: World, e: Entity, comp: anytype) void {
        c.ecs_add_id(self.raw, e, comp.asId());
    }

    pub inline fn addId(self: World, e: Entity, id: Id) void {
        c.ecs_add_id(self.raw, e, id);
    }

    /// Adds a relationship pair, such as `(ChildOf, parent)`.
    pub inline fn addPair(self: World, e: Entity, first: Entity, second: Entity) void {
        c.ecs_add_id(self.raw, e, types.pair(first, second));
    }

    pub inline fn remove(self: World, e: Entity, comp: anytype) void {
        c.ecs_remove_id(self.raw, e, comp.asId());
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
            c.ecs_add_id(self.raw, e, comp.asId());
            return;
        }
        var local = value;
        c.ecs_set_id(self.raw, e, comp.asId(), @sizeOf(T), &local);
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
        const ptr = c.ecs_get_id(self.raw, e, comp.asId()) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Reads a component for modification. Null when the entity does not have it.
    ///
    /// Changing the value through this pointer does not notify observers watching for
    /// `OnSet`; call `modified` when you are done if anything is listening.
    pub inline fn getMut(self: World, e: Entity, comp: anytype) ?*@TypeOf(comp).Type {
        const ptr = c.ecs_get_mut_id(self.raw, e, comp.asId()) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Reads a component, adding it first if the entity does not have it. Never null
    /// for a component with data.
    pub inline fn ensure(self: World, e: Entity, comp: anytype) *@TypeOf(comp).Type {
        const T = @TypeOf(comp).Type;
        const ptr = c.ecs_ensure_id(self.raw, e, comp.asId(), @sizeOf(T)).?;
        return @ptrCast(@alignCast(ptr));
    }

    /// Announces that a component was changed through `getMut` or `ensure`, so that
    /// `OnSet` observers run.
    pub inline fn modified(self: World, e: Entity, comp: anytype) void {
        c.ecs_modified_id(self.raw, e, comp.asId());
    }

    pub inline fn has(self: World, e: Entity, comp: anytype) bool {
        return c.ecs_has_id(self.raw, e, comp.asId());
    }

    pub inline fn hasId(self: World, e: Entity, id: Id) bool {
        return c.ecs_has_id(self.raw, e, id);
    }

    /// Whether the entity has the component itself, rather than inheriting it from a
    /// prefab or a parent.
    pub inline fn owns(self: World, e: Entity, comp: anytype) bool {
        return c.ecs_owns_id(self.raw, e, comp.asId());
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
        return .{ .raw = c.ecs_each_id(self.raw, comp.asId()) };
    }

    pub fn eachId(self: World, id: Id) EachIterator {
        return .{ .raw = c.ecs_each_id(self.raw, id) };
    }

    pub fn system(self: World, desc: system_mod.SystemDesc) Error!Entity {
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
    return .{ .id = types.pair(pairElement(first), pairElement(second)) };
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

//=============================================================================
// Component lifecycle hooks, derived from the Zig type
//
// flecs asks for eight function pointers to describe how a component is constructed,
// destroyed, copied and moved. Zig answers most of that by itself, so most of the eight
// should stay null, and getting which ones right is the whole content of this section.
//
// Relocation first, because it is the one flecs cannot guess. A Zig value has no move
// constructor and no identity: relocating it is a memcpy, and the source is not left
// needing anything. That is exactly what flecs does when `move` is null — it memcpys
// into the destination and does not destruct the source — so a Zig type wants no move
// hook at all. Setting one would be worse than useless: flecs would then treat the move
// as non-trivial and destruct the source after every table change, freeing what the
// destination now owns.
//
// Copying is the opposite case: Zig has no copy constructor either, so there is nothing
// to derive. A bitwise copy of a value that owns memory produces two owners. flecs uses
// the copy hook for two things it cannot tell apart — overwriting a component with a
// new value, which in Zig is a hand-over, and duplicating one into another entity, which
// is not expressible. This derives the hand-over, because that is what `set` does and
// `set` is the common call; the consequence is stated on `typeHooks`.
//=============================================================================

/// flecs's lifecycle hooks for `T`, worked out at compile time.
///
/// A plain-data component gets nothing — the empty hook set, which is what flecs
/// assumes anyway — so this costs nothing to apply to a type that does not need it.
///
/// A component with a `deinit` method gets:
///
/// - a destructor that calls it, so removing the component, deleting the entity or
///   destroying the world releases what the value owns;
/// - a constructor, when every field of `T` has a default, so a value flecs creates on
///   its own is `T{}` rather than zeroes. Without one, flecs zeroes the memory;
/// - a copy that destroys what the destination held before taking the source's bits.
///   Setting a component twice therefore frees the first value instead of leaking it,
///   and `set` reads as handing ownership to the world.
///
/// Which puts one requirement on the type: `deinit` has to be safe to call on a value
/// flecs constructed and nothing has been written to yet — `T{}`, or all zeroes when
/// there is no `T{}` to write. That value is what the copy destroys before it takes the
/// first value a component is ever set to.
///
/// The unrepresentable case is duplication: `ecs_clone` and instantiating a prefab that
/// carries an owning component will produce two values pointing at one allocation.
/// Zig has no copy constructor to derive one from, so a component with a `deinit`
/// should not be put on a prefab.
///
/// `deinit` must take exactly one parameter, the value. A `deinit` that also wants an
/// allocator — `std.ArrayList`'s, among others — cannot be called from a flecs hook,
/// which is handed nothing but the pointer, so that is a compile error here rather than
/// a surprise later. Wrap such a type in one that remembers its allocator.
pub fn typeHooks(comptime T: type) c.ecs_type_hooks_t {
    // flecs refuses hooks on a zero-sized component, and there is nothing for them to
    // act on anyway.
    if (comptime @sizeOf(T) == 0) return .{};
    if (comptime !hasDeinit(T)) return .{};

    const thunks = Thunks(T);
    return .{
        .ctor = if (comptime hasDefaultValue(T)) &thunks.ctor else null,
        .dtor = &thunks.dtor,
        .copy = &thunks.copy,
    };
}

/// The C-ABI functions flecs holds for `T`. Generated per type at compile time, so each
/// one is an ordinary loop over a typed slice rather than a walk through a `void*`.
fn Thunks(comptime T: type) type {
    return struct {
        fn ctor(ptr: ?*anyopaque, count: i32, _: ?*const c.ecs_type_info_t) callconv(.c) void {
            for (slice(ptr, count)) |*value| value.* = .{};
        }

        fn dtor(ptr: ?*anyopaque, count: i32, _: ?*const c.ecs_type_info_t) callconv(.c) void {
            for (slice(ptr, count)) |*value| value.deinit();
        }

        fn copy(
            dst: ?*anyopaque,
            src: ?*const anyopaque,
            count: i32,
            _: ?*const c.ecs_type_info_t,
        ) callconv(.c) void {
            const from: [*]const T = @ptrCast(@alignCast(src.?));
            for (slice(dst, count), from[0..@intCast(count)]) |*to, *value| {
                // The destination is a live component. flecs's own default here is a
                // memcpy over it, which would strand whatever it owned.
                to.deinit();
                to.* = value.*;
            }
        }

        inline fn slice(ptr: ?*anyopaque, count: i32) []T {
            const typed: [*]T = @ptrCast(@alignCast(ptr.?));
            return typed[0..@intCast(count)];
        }
    };
}

fn hasDeinit(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {},
        else => return false,
    }
    if (!@hasDecl(T, "deinit")) return false;
    const Deinit = @TypeOf(@field(T, "deinit"));
    if (@typeInfo(Deinit) != .@"fn") return false;
    if (@typeInfo(Deinit).@"fn".params.len != 1) @compileError(
        "zecs cannot derive a destructor for " ++ @typeName(T) ++ ": its `deinit` takes " ++
            "more than the value, and a flecs hook is handed nothing else. Wrap the type " ++
            "in one whose `deinit` needs no arguments, or write the hooks by hand.",
    );
    return true;
}

/// Whether `T{}` is a value: every field has a default, so flecs can construct one
/// without being told anything.
fn hasDefaultValue(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| for (info.fields) |field| {
            if (field.default_value_ptr == null) break false;
        } else true,
        else => false,
    };
}
