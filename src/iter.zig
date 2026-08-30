//! Reading the results of a query, a system or an observer.
//!
//! An iterator arrives holding one *table* — a run of entities that all have the same
//! set of components — so a field is a contiguous slice and iteration is a loop over
//! arrays rather than a walk over objects. That is the whole performance argument for
//! an archetype ECS, and this type is the place it either survives contact with Zig or
//! does not.
//!
//! `Iter` is one pointer. In a release build the wrapper compiles away entirely: the
//! accessors are `inline`, and the field lookups are the same C calls a C program would
//! make.

const std = @import("std");
const c = @import("c/iter.zig");
const types = @import("types.zig");

const Entity = types.Entity;
const Id = types.Id;

pub const Iter = struct {
    raw: *c.ecs_iter_t,

    /// Wraps a raw iterator, for code that took a C callback directly.
    pub inline fn fromRaw(raw: *c.ecs_iter_t) Iter {
        return .{ .raw = raw };
    }

    /// Entities in the current table.
    pub inline fn count(self: Iter) usize {
        return @intCast(self.raw.count);
    }

    /// The entities themselves, in the same order as every field slice.
    pub inline fn entities(self: Iter) []const Entity {
        const ptr = self.raw.entities orelse return &.{};
        return ptr[0..self.count()];
    }

    /// Seconds since the last frame, as passed to `progress`.
    pub inline fn deltaTime(self: Iter) c.ecs_ftime_t {
        return self.raw.delta_time;
    }

    /// Seconds since this system last ran, which differs from `deltaTime` for systems
    /// with an interval or a rate.
    pub inline fn deltaSystemTime(self: Iter) c.ecs_ftime_t {
        return self.raw.delta_system_time;
    }

    /// The context pointer set on the query, system or observer.
    pub inline fn ctx(self: Iter) ?*anyopaque {
        return self.raw.ctx;
    }

    /// The parameter passed to `ecs_run`, if any.
    pub inline fn param(self: Iter) ?*anyopaque {
        return self.raw.param;
    }

    /// The system currently running, or 0.
    pub inline fn system(self: Iter) Entity {
        return self.raw.system;
    }

    /// For observers: the event that fired, and the id it fired for.
    pub inline fn event(self: Iter) Entity {
        return self.raw.event;
    }

    pub inline fn eventId(self: Iter) Id {
        return self.raw.event_id;
    }

    //=========================================================================
    // Fields
    //
    // A term matched through `Up`, `Cascade` or a fixed source resolves to ONE value
    // shared by every entity in the table, not an array of them. flecs signals this
    // through `ecs_field_is_self`, and a binding that ignores it hands out a slice of
    // `count` elements over a single value — reads past the first entity are then
    // out of bounds, silently, on exactly the queries that use inheritance.
    //
    // So `field` asks, and returns a slice of the right length. `fieldSelf` is the
    // version that skips the question for terms known to be per-entity, and asserts it
    // in safe builds.
    //=========================================================================

    /// Bounds flecs itself checks with `ecs_check`, which a release build compiles out —
    /// see the module comment on `Table.column` for the same pattern. Every accessor
    /// below takes a field index, so every one of them checks it here first: with safety
    /// off, an out-of-range index would otherwise read past `it->columns`, `it->ids` or
    /// `it->sources` instead of hitting an assertion.
    inline fn checkFieldIndex(self: Iter, index: i8) void {
        std.debug.assert(index >= 0 and index < self.raw.field_count);
    }

    /// The field at `index`, sized correctly whether it is per-entity or shared.
    /// Null when the term is optional and did not match.
    pub inline fn field(self: Iter, comptime T: type, index: i8) ?[]T {
        self.checkFieldIndex(index);
        const ptr = c.ecs_field_w_size(self.raw, @sizeOf(T), index) orelse return null;
        const typed: [*]T = @ptrCast(@alignCast(ptr));
        const len = if (c.ecs_field_is_self(self.raw, index)) self.count() else 1;
        return typed[0..len];
    }

    /// The field at `index`, which must be per-entity. One C call cheaper than `field`,
    /// and the assertion that it really is per-entity is compiled out in ReleaseFast.
    pub inline fn fieldSelf(self: Iter, comptime T: type, index: i8) []T {
        self.checkFieldIndex(index);
        const ptr = c.ecs_field_w_size(self.raw, @sizeOf(T), index).?;
        std.debug.assert(c.ecs_field_is_self(self.raw, index));
        const typed: [*]T = @ptrCast(@alignCast(ptr));
        return typed[0..self.count()];
    }

    /// The single value behind a field matched from somewhere else — a parent, a
    /// prefab, a fixed source. Null when the term did not match.
    pub inline fn fieldShared(self: Iter, comptime T: type, index: i8) ?*T {
        self.checkFieldIndex(index);
        const ptr = c.ecs_field_w_size(self.raw, @sizeOf(T), index) orelse return null;
        std.debug.assert(!c.ecs_field_is_self(self.raw, index));
        return @ptrCast(@alignCast(ptr));
    }

    /// Whether an optional or conditionally-set field has a value.
    pub inline fn isSet(self: Iter, index: i8) bool {
        self.checkFieldIndex(index);
        return c.ecs_field_is_set(self.raw, index);
    }

    /// Whether the field came from the matched entity rather than through traversal.
    pub inline fn isSelf(self: Iter, index: i8) bool {
        self.checkFieldIndex(index);
        return c.ecs_field_is_self(self.raw, index);
    }

    /// The id the term matched — useful when the term held a wildcard.
    pub inline fn fieldId(self: Iter, index: i8) Id {
        self.checkFieldIndex(index);
        return c.ecs_field_id(self.raw, index);
    }

    /// The entity a field was matched on, or 0 when it is the iterated entity.
    pub inline fn fieldSrc(self: Iter, index: i8) Entity {
        self.checkFieldIndex(index);
        return c.ecs_field_src(self.raw, index);
    }

    //=========================================================================
    // Advancing and releasing
    //=========================================================================

    /// Advances to the next table. Iterators handed to a callback are already
    /// positioned, so this is for iterators you created yourself.
    pub inline fn next(self: Iter) bool {
        const advance = self.raw.next orelse return false;
        return advance(self.raw);
    }

    /// Releases the iterator's resources.
    ///
    /// Only needed when iteration stops early: running an iterator to completion
    /// releases it, and calling this afterwards is not allowed. `Iterator` below — and
    /// `QueryOf.Iterator`, which wraps it — track which happened, so `defer it.deinit()`
    /// is correct either way; this is the raw call underneath them.
    pub inline fn deinit(self: Iter) void {
        c.ecs_iter_fini(self.raw);
    }
};

/// Turns a Zig function into the C callback flecs stores.
///
/// The thunk is generated at compile time and the wrapper is one pointer, so this
/// produces the same code as writing the C-ABI function by hand — while letting the
/// function itself be ordinary Zig.
///
/// ```zig
/// fn move(it: *zecs.Iter) void { ... }
/// ...
/// .callback = zecs.callback(move),
/// ```
pub fn callback(comptime handler: fn (it: *Iter) void) c.ecs_iter_action_t {
    return &struct {
        fn thunk(raw: *c.ecs_iter_t) callconv(.c) void {
            var it = Iter{ .raw = raw };
            handler(&it);
        }
    }.thunk;
}

/// An iteration in progress, owning the `ecs_iter_t` it walks.
///
/// The C struct is returned by value and the iterator holds a pointer into itself, so
/// somebody has to own the storage. Making that explicit also solves a second problem:
/// flecs releases an iterator automatically when iteration runs to the end, so calling
/// `ecs_iter_fini` after a completed loop is a double free, while *not* calling it after
/// an early `break` is a leak. This type tracks which happened, so `defer it.deinit()`
/// is correct either way.
///
/// `advance` is comptime, so the loop calls flecs's iteration function directly rather
/// than through the function pointer in the struct.
///
/// ## Copying one is a bug, and it is checked
///
/// Once iteration has started, an `ecs_iter_t` is not a value. It holds a cursor into
/// the stage's iterator stack (`libs/flecs/flecs.c:13203`) that `ecs_iter_fini` pops,
/// and `it.ids`, `it.sources`, `it.trs` and `it.columns` point into memory that cursor
/// owns. flecs treats it that way itself: where it does copy an iterator, it clears the
/// cursor by hand first — `result.priv_.stack_cursor = NULL; /* Don't copy allocator
/// cursor */`, flecs.c:13998 and :14103 — and elsewhere it copies only the public half,
/// `memcpy(it, chain_it, offsetof(ecs_iter_t, priv_))`, flecs.c:14031.
///
/// So a copy taken after the first `next()` is two owners of one iteration: each will
/// pop the same cursor, and advancing one leaves the other reading a table it has been
/// moved off. Zig cannot forbid a copy, so this asserts against one. The first `next()`
/// or `deinit()` records the address the iterator is at, and every later call requires
/// it to still be there — which catches a copy and a move alike, both of which are the
/// same defect. Before the first `next()` there is nothing to keep in step, so
/// returning one of these by value is fine and is how they are all built.
pub fn Iterator(comptime advance: *const fn (*c.ecs_iter_t) callconv(.c) bool) type {
    return struct {
        const Self = @This();

        raw: c.ecs_iter_t,
        finished: bool = false,
        /// Where this iterator was when it was first used. Null until then.
        home: ?*const Self = null,

        /// The next table, or null when there are none left.
        pub fn next(self: *Self) ?Iter {
            std.debug.assert(self.atHome());
            self.home = self;
            if (self.finished) return null;
            if (advance(&self.raw)) return Iter{ .raw = &self.raw };
            // flecs released it on the way out.
            self.finished = true;
            return null;
        }

        /// Releases the iterator if the loop did not run to completion.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.atHome());
            self.home = self;
            if (self.finished) return;
            self.finished = true;
            c.ecs_iter_fini(&self.raw);
        }

        /// Whether this iterator is still where it was first used.
        ///
        /// True for one that has not been used yet, which is the only state in which
        /// moving it is legal. Public and separate from the assertion built on it for
        /// the usual reason: an assertion cannot be caught, so from inside the language
        /// a check wired up wrongly and a check that never fires look the same.
        pub fn atHome(self: *const Self) bool {
            const home = self.home orelse return true;
            return home == self;
        }
    };
}
