//! Tables: what an archetype ECS actually stores, and how to reach it directly.
//!
//! Every entity that has the same set of components lives in the same table, and the
//! table keeps one contiguous array — a column — per component in that set. Iterating a
//! query hands out slices of those arrays, and that is the whole performance argument
//! for this kind of ECS. This file is the other door into the same storage: given a
//! table, take the column and work on it as an array.
//!
//! flecs hands a column out as `void*` and trusts the caller to know both the element
//! type and how many elements there are. `Table.column` asks flecs for both — the
//! element size from the table's own type info, the length from `ecs_table_count` — and
//! returns a `[]T`.
//!
//! ## What invalidates a column slice
//!
//! The slice points into flecs's storage rather than into a copy of it, so it is valid
//! for exactly as long as the column array neither moves nor changes length. It
//! survives writes through itself, and reads of anything at all. It does not survive:
//!
//! - adding or removing a component, a tag or a pair on **any** entity in the table.
//!   The entity moves to a different table and the row it vacated is filled by moving
//!   the last row into it, so values shift even for entities that were not touched.
//!   `World.set` does this too, when the entity did not already have the component;
//! - deleting any entity in the table, or clearing the table;
//! - creating an entity in the table, or moving one into it. Columns grow by
//!   reallocating, and every slice into them dangles when they do;
//! - `swapRows`, and the raw operations that rewrite the layout rather than the values:
//!   `ecs_commit`, `ecs_bulk_init`, `ecs_table_clear_entities`;
//! - the world being destroyed.
//!
//! Deferring does not repeal the rule, it reschedules it. Inside `World.deferBegin` the
//! structural operations are recorded instead of applied, so a slice taken before them
//! stays good — and `deferEnd` applies the lot at once, which invalidates it.
//!
//! `count` and `capacity` are the two numbers this turns on: an insert reallocates when
//! the first reaches the second.
//!
//! ## The enforcement flecs offers
//!
//! `lock` marks a table as being read. Every structural change to a locked table trips
//! an assertion inside flecs and aborts the process, which is a great deal better than
//! the alternative. That assertion is compiled in when flecs was built with its checks
//! on — `zecs.options.debug_checks != .none`, which the default `auto` selects for a
//! Debug build — and compiled out otherwise, where the same mistake corrupts memory
//! quietly. So hold the lock for as long as a slice is live:
//!
//! ```zig
//! const held = table.lock();
//! defer held.unlock();
//! for (table.column(Position, index)) |*p| p.x += 1;
//! ```
//!
//! The lock is a counter, not a mutex. It stops flecs from moving the storage out from
//! under a reader on the same thread; it does not stop a second thread. `writeBegin` is
//! the one that claims an entity's table against other threads.

const std = @import("std");
const c = @import("c/table.zig");
const types = @import("types.zig");
const iter_mod = @import("iter.zig");
const world_mod = @import("world.zig");
const Error = @import("error.zig").Error;

const Entity = types.Entity;
const Id = types.Id;
const World = world_mod.World;
const Iter = iter_mod.Iter;

/// One archetype's storage: the entities that share a set of components, and the
/// columns holding those components.
///
/// The world travels with the table because half of flecs's table operations need it,
/// and because a bare `*ecs_table_t` cannot be paired with the wrong world if it is
/// never handed out on its own. A table is a borrowed view — flecs owns it, creates and
/// destroys it as entities move, and there is nothing here to release.
///
/// Anything not covered here is reachable raw: the fields are public, so
/// `zecs.c.table.ecs_table_get_target(table.world, table.raw, rel, 0)` is a first-class way
/// to call the rest of the API.
pub const Table = struct {
    raw: *c.ecs_table_t,
    world: *c.ecs_world_t,

    /// Locks the storage against structural change for as long as it is held.
    ///
    /// See the note at the top of this file for what "structural" means and what flecs
    /// does about a violation. The lock is recursive: an equal number of unlocks is
    /// needed to release it, and flecs asserts on one too many.
    pub const Lock = struct {
        table: Table,

        pub fn unlock(self: Lock) void {
            c.ecs_table_unlock(self.table.world, self.table.raw);
        }
    };

    //=========================================================================
    // Finding one
    //=========================================================================

    /// The table an entity currently lives in.
    ///
    /// An entity with no components is not null: flecs puts it in the root table, which
    /// has no ids and no columns but is a table like any other. Null is what flecs
    /// returns for an entity it has no record for, which it otherwise treats as a
    /// programming error and asserts on.
    pub fn of(world: World, e: Entity) ?Table {
        return .{ .raw = c.ecs_get_table(world.raw, e) orelse return null, .world = world.raw };
    }

    /// The table the iterator is positioned on. Null for a result with no table behind
    /// it — an observer for an entity that has just lost its last component, a term
    /// matched entirely from a fixed source.
    ///
    /// The iterator may be looking at only part of the table. `Iter.entities` and the
    /// field slices cover `it.raw.offset` to `it.raw.offset + it.raw.count`, while a
    /// column taken from here is always the whole column and `Table.entities` is always
    /// every entity in the table. Compare the two by entity, not by index.
    pub fn fromIter(it: Iter) ?Table {
        // Iteration can be running against a stage rather than the world itself, and
        // the table operations that take a world assert they were handed the real one.
        return .{
            .raw = it.raw.table orelse return null,
            .world = it.raw.real_world orelse return null,
        };
    }

    //=========================================================================
    // Shape
    //=========================================================================

    /// Entities in the table. Also the length of every column.
    pub inline fn count(self: Table) usize {
        return @intCast(c.ecs_table_count(self.raw));
    }

    /// Rows the columns have room for. An insert past this reallocates every column,
    /// which is the event the invalidation rules at the top of this file are about.
    pub inline fn capacity(self: Table) usize {
        return @intCast(c.ecs_table_size(self.raw));
    }

    /// Columns in the table, which is the bound on `column`'s index.
    ///
    /// Smaller than `ids().len` whenever the table holds a tag or a pair with no data:
    /// those are part of the archetype but take no storage, so they have no column.
    pub inline fn columnCount(self: Table) usize {
        return @intCast(c.ecs_table_column_count(self.raw));
    }

    /// The table's type: every component, tag and pair id in it, in flecs's order.
    ///
    /// This is what flecs calls the table's type, and it is the index space that
    /// `typeIndex` and `columnToTypeIndex` answer in.
    pub inline fn ids(self: Table) []const Id {
        const t = c.ecs_table_get_type(self.raw) orelse return &.{};
        const array = t.array orelse return &.{};
        const many: [*]const Id = @ptrCast(array);
        return many[0..@intCast(t.count)];
    }

    /// The entities in the table, in the same order as every column.
    pub inline fn entities(self: Table) []const Entity {
        const ptr = c.ecs_table_entities(self.raw) orelse return &.{};
        const many: [*]const Entity = @ptrCast(ptr);
        return many[0..self.count()];
    }

    //=========================================================================
    // Columns
    //=========================================================================

    /// The whole of column `index`, as a slice of `count` elements of `T`.
    ///
    /// `index` is a column index, not an index into `ids`: use `columnIndex` to find it
    /// from a component, or `typeToColumnIndex` to convert one you already have. An
    /// empty table gives an empty slice, because flecs allocates a column's storage
    /// with its first row.
    ///
    /// Where Zig's safety checks are on — Debug and ReleaseSafe — the index is checked
    /// against `columnCount` and `T` against the element size flecs recorded for the
    /// column. With safety off the wrong `T` is a silently misread array rather than a
    /// crash. Read the invalidation rules at the top of this file before keeping the
    /// slice for longer than the loop that uses it.
    pub inline fn column(self: Table, comptime T: type, index: usize) []T {
        // A zero-sized component is a tag, and a tag has no column to ask for.
        comptime std.debug.assert(@sizeOf(T) != 0);
        std.debug.assert(index < self.columnCount());
        std.debug.assert(c.ecs_table_get_column_size(self.raw, @intCast(index)) == @sizeOf(T));

        const ptr = c.ecs_table_get_column(self.raw, @intCast(index), 0) orelse return &.{};
        const many: [*]T = @ptrCast(@alignCast(ptr));
        return many[0..self.count()];
    }

    /// The column holding `comp`, or null when the table does not have that component.
    ///
    /// flecs's own `ecs_table_get_id` returns null for two different things — the table
    /// does not have the component, and the table has it but has no rows yet, so the
    /// column has no allocation. Those must not be the same answer, so this asks for
    /// the index first and lets `column` return an empty slice for the second case.
    pub inline fn columnOf(self: Table, comp: anytype) ?[]@TypeOf(comp).Type {
        const index = self.columnIndex(comp.asId()) orelse return null;
        return self.column(@TypeOf(comp).Type, index);
    }

    /// The column index for an id, or null when the table has no column for it —
    /// either because the table does not have the id at all, or because the id is a tag
    /// and carries no data.
    pub inline fn columnIndex(self: Table, id: Id) ?usize {
        const index = c.ecs_table_get_column_index(self.world, self.raw, id);
        return if (index < 0) null else @intCast(index);
    }

    /// The index of an id in `ids`, or null when the table does not have it. Unlike
    /// `columnIndex` this answers for tags and data-less pairs too.
    pub inline fn typeIndex(self: Table, id: Id) ?usize {
        const index = c.ecs_table_get_type_index(self.world, self.raw, id);
        return if (index < 0) null else @intCast(index);
    }

    /// The column an entry of `ids` is stored in, or null when that entry is a tag and
    /// has no storage. Unlike the two below it, this null is an ordinary answer.
    pub inline fn typeToColumnIndex(self: Table, index: usize) ?usize {
        const found = c.ecs_table_type_to_column_index(self.raw, @intCast(index));
        return if (found < 0) null else @intCast(found);
    }

    /// The entry of `ids` a column belongs to. The inverse of `typeToColumnIndex`, and
    /// total: every column belongs to something in the type, so null here means the
    /// index was not a column. flecs asserts that and aborts on it in a build with its
    /// checks on, which leaves this reachable only under `-Dsoft_assert`.
    pub inline fn columnToTypeIndex(self: Table, index: usize) ?usize {
        const found = c.ecs_table_column_to_type_index(self.raw, @intCast(index));
        return if (found < 0) null else @intCast(found);
    }

    /// The size of one element of a column, as flecs recorded it when the component was
    /// registered. This is what `column` checks `T` against.
    ///
    /// Null when `index` is not a column — a stored component always has a non-zero
    /// size, so flecs's zero is unambiguous. As with `columnToTypeIndex`, flecs aborts
    /// on an out-of-range index in a checked build rather than returning, so this is
    /// null only under `-Dsoft_assert`.
    pub inline fn columnSize(self: Table, index: usize) ?usize {
        const size = c.ecs_table_get_column_size(self.raw, @intCast(index));
        return if (size == 0) null else size;
    }

    //=========================================================================
    // Structure
    //=========================================================================

    /// See `Lock`. Pair it with `defer held.unlock()`.
    pub inline fn lock(self: Table) Lock {
        c.ecs_table_lock(self.world, self.raw);
        return .{ .table = self };
    }

    /// The table an entity of this table would land in if `id` were added to it.
    ///
    /// This walks the archetype graph; it moves nothing and changes no entity. flecs
    /// creates the destination table if it does not exist yet, and returns this table
    /// unchanged when it already has the id.
    pub fn addId(self: Table, id: Id) ?Table {
        return .{ .raw = c.ecs_table_add_id(self.world, self.raw, id) orelse return null, .world = self.world };
    }

    /// The counterpart of `addId`: where an entity would land if `id` were removed.
    pub fn removeId(self: Table, id: Id) ?Table {
        return .{ .raw = c.ecs_table_remove_id(self.world, self.raw, id) orelse return null, .world = self.world };
    }

    /// Exchanges two rows, in every column and in `entities` alike.
    ///
    /// This is the primitive a custom sort is built from. It is a structural change, so
    /// it invalidates any slice held across it — including one being sorted, which has
    /// to be re-taken after each swap or taken once and swapped by hand.
    pub fn swapRows(self: Table, row_a: usize, row_b: usize) void {
        c.ecs_table_swap_rows(self.world, self.raw, @intCast(row_a), @intCast(row_b));
    }

    /// How deep this table sits in the tree formed by `rel` — zero for a table whose
    /// entities have no such relationship, one for the children of those, and so on.
    ///
    /// Null when flecs could not answer. `rel` has to be acyclic, and flecs aborts on
    /// one that is not rather than returning, so in practice this is null only in a
    /// build with `-Dsoft_assert`.
    pub fn depth(self: Table, rel: Entity) ?usize {
        const found = c.ecs_table_get_depth(self.world, self.raw, rel);
        return if (found < 0) null else @intCast(found);
    }

    /// The table's type as flecs prints it: `"Position, Velocity, (ChildOf, parent)"`.
    ///
    /// The caller owns the string and frees it with `zecs.freeString`.
    pub fn str(self: Table) ?[:0]u8 {
        return std.mem.span(c.ecs_table_str(self.world, self.raw) orelse return null);
    }
};

//=============================================================================
// Records
//
// A record is where flecs keeps an entity: which table, and which row of it. Looking
// one up once and reading several components through it is the fast path for touching
// an entity that is known to sit still, because the entity index is consulted once
// instead of once per component.
//=============================================================================

/// Where an entity lives. Borrowed from the world, and invalidated by the same things
/// that invalidate a column slice.
pub const Record = struct {
    raw: *const c.ecs_record_t,

    /// The record for an entity.
    ///
    /// The entity has to be alive. flecs asserts that and aborts on an entity that is
    /// not, in a build with its checks on; the null this returns is flecs's own
    /// unreachable path, which a build without checks falls into instead. So check
    /// `World.isAlive` first rather than treating the null as the answer.
    pub fn find(world: World, e: Entity) ?Record {
        return .{ .raw = c.ecs_record_find(world.raw, e) orelse return null };
    }

    /// The table the entity is in. An entity with no components is in the root table,
    /// not in none; null is the transient state flecs leaves a record in while the
    /// entity is being created or torn down.
    pub fn table(self: Record, world: World) ?Table {
        return .{ .raw = self.raw.table orelse return null, .world = world.raw };
    }

    /// This entity's own element of column `index` of its table.
    ///
    /// The index is the table's, from `Table.columnIndex`; hoisting that lookup out of
    /// a loop over entities in one table is the reason this exists. In a build with
    /// flecs's checks on it verifies `@sizeOf(T)` against the column's element size and
    /// aborts on an index out of range, so the null is reachable only under
    /// `-Dsoft_assert`.
    pub inline fn column(self: Record, comptime T: type, index: usize) ?*T {
        comptime std.debug.assert(@sizeOf(T) != 0);
        const ptr = c.ecs_record_get_by_column(self.raw, @intCast(index), @sizeOf(T)) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }
};

/// Exclusive access to the table an entity lives in.
///
/// This is flecs's direct-access API for reading and writing components from a thread
/// other than the one driving the world. Claiming it locks the entity's table, so a
/// second `writeBegin` against the same table is refused rather than raced; releasing
/// it unlocks. Structural changes are not allowed while it is held, and it has to be
/// ended before the world is used normally again.
///
/// It needs the OS API's threading functions, which the `os_api_impl` addon supplies
/// and every addon preset includes.
pub const Write = struct {
    raw: *c.ecs_record_t,

    pub inline fn record(self: Write) Record {
        return .{ .raw = self.raw };
    }

    pub fn end(self: Write) void {
        c.ecs_write_end(self.raw);
    }
};

/// Shared access to the table an entity lives in. Several readers may hold one at once;
/// a `writeBegin` while any of them do is refused. See `Write`.
pub const Read = struct {
    raw: *const c.ecs_record_t,

    pub inline fn record(self: Read) Record {
        return .{ .raw = self.raw };
    }

    pub fn end(self: Read) void {
        c.ecs_read_end(self.raw);
    }
};

/// Claims exclusive access to an entity's row. Pair with `defer held.end()`.
///
/// Fails when flecs refuses the claim: the OS API has no threading, or another writer
/// already holds this table. flecs reports both by aborting unless it was built with
/// `-Dsoft_assert`, in which case it returns nothing and this returns the error.
pub fn writeBegin(world: World, e: Entity) Error!Write {
    return .{ .raw = c.ecs_write_begin(world.raw, e) orelse return Error.RecordAccessDenied };
}

/// Claims shared access to an entity's row. Pair with `defer held.end()`. See
/// `writeBegin` for how it fails.
pub fn readBegin(world: World, e: Entity) Error!Read {
    return .{ .raw = c.ecs_read_begin(world.raw, e) orelse return Error.RecordAccessDenied };
}

//=============================================================================
// Refs
//=============================================================================

/// A cached pointer to one component on one entity.
///
/// flecs's answer to calling `World.get` in a loop for the same entity: a ref remembers
/// the table and the row and revalidates them against a version counter, which is
/// several times faster than the lookup. It survives the entity moving between tables —
/// revalidating is precisely what it is for — and starts reporting null once the entity
/// is deleted.
///
/// Every call has to name the same component the ref was created with. flecs keeps the
/// id to check that only in a build with `FLECS_DEBUG`, and the check is the reason
/// `ecs_ref_t` is a different size there; here the component is part of the ref, so it
/// cannot be got wrong in any build.
///
/// `zecs.c.entity.ecs_ref_update(world.raw, &r.raw, r.component)` refreshes a ref without
/// reading through it, for revalidating a batch in one pass. It has no wrapper because
/// a useful one would have to hand back the pointer, at which point it is `get`.
pub fn Ref(comptime T: type) type {
    return struct {
        const Self = @This();

        raw: c.ecs_ref_t,
        component: Id,

        /// The current pointer, or null once the entity is gone. Cheap enough to call
        /// per frame; the point of a ref is that this is not a lookup.
        pub inline fn get(self: *Self, world: World) ?*T {
            const ptr = c.ecs_ref_get_id(world.raw, &self.raw, self.component) orelse return null;
            return @ptrCast(@alignCast(ptr));
        }
    };
}

/// Creates a ref for a component on an entity.
///
/// Fails when the entity is not alive, or has no components at all — flecs will not
/// make a ref for an entity that is in no table.
pub inline fn ref(world: World, e: Entity, comp: anytype) Error!Ref(@TypeOf(comp).Type) {
    const raw = c.ecs_ref_init_id(world.raw, e, comp.asId());
    // flecs signals failure by handing back a zeroed struct, which is indistinguishable
    // from a valid ref in every field except this one.
    if (raw.entity == 0) return Error.RefInitFailed;
    return .{ .raw = raw, .component = comp.asId() };
}
