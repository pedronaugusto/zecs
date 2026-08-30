//! Component registration, and the typed handle that comes back.
//!
//! A `Component(T)` is an entity id with a type attached at compile time. It is a
//! single integer at runtime — there is no per-type global cache, and no lookup on the
//! way to `set` or `get`. The type parameter is what makes those operations checkable:
//! `world.set(e, position, .{ .x = 1 })` will not compile if `position` is a
//! `Component(Velocity)`, and the size passed to flecs is always `@sizeOf(T)`.
//!
//! Component ids belong to the world that registered them. Keeping the id in a value
//! the caller holds, rather than in a global keyed by type, is what makes two worlds in
//! one process work — and the handle remembers WHICH world, because that is the half
//! that could not be checked otherwise. flecs hands out the next free entity id, so two
//! worlds registering different components in a different order routinely give them the
//! same number: world A's `Position` and world B's `Velocity` can be id 512 in both, and
//! `world_b.set(e, position_from_a, …)` then writes a `Velocity`-shaped hole with a
//! `Position` and reports nothing. `World` compares the two before every typed
//! operation.

const std = @import("std");
const c = @import("c/core.zig");
const types = @import("types.zig");

const Entity = types.Entity;
const Id = types.Id;

/// The strongest alignment flecs gives a component's storage.
///
/// A table's column is allocated with `ecs_os_malloc(component_size * count)` —
/// `libs/flecs/flecs.c:44676`, and every other place a column is created or grown has
/// the same shape — and neither `ecs_os_malloc` nor the block allocator behind it takes
/// an alignment argument. What comes back is C's `malloc` guarantee, which is 16 bytes
/// on every target this package builds for. `src/os.zig` holds its own bridge to
/// exactly 16 so that installing a Zig allocator is not weaker than leaving libc's in
/// place.
///
/// This is flecs's limit, not one this package chose, and it is not a policy: a
/// component wanting more is not stored badly, it is stored at an address the CPU may
/// fault on. It moves the day flecs grows an aligned allocation path — and the refusal
/// below is what will make that a visible change rather than a silent one.
pub const max_alignment: u29 = 16;

/// Whether flecs can store `T` at the alignment `T` requires.
///
/// Separate from the `@compileError` that uses it so that the rule itself is testable:
/// a `@compileError` cannot be caught, so a refusal wired up wrongly and a refusal that
/// never fires look identical from inside the language. The tests below drive this on
/// types either side of the limit, and `ci/mutate.sh` proves the wiring by planting an
/// over-aligned component and requiring the build to fail.
pub fn isStorable(comptime T: type) bool {
    return @alignOf(T) <= max_alignment;
}

/// The refusal. Reached by resolving `Component(T)`, which every route to a registered
/// component goes through.
fn requireStorable(comptime T: type) void {
    if (!isStorable(T)) @compileError(
        "zecs cannot store " ++ @typeName(T) ++ " as a component: it needs " ++
            std.fmt.comptimePrint("{d}", .{@alignOf(T)}) ++ "-byte alignment and flecs " ++
            "allocates component columns with a plain `ecs_os_malloc`, which guarantees " ++
            std.fmt.comptimePrint("{d}", .{max_alignment}) ++ ". flecs would put the " ++
            "column at an address this type may not legally live at, and neither " ++
            "compiler would say so. Store it behind a pointer or a handle the component " ++
            "holds, or lower the alignment.",
    );
}

/// A registered component, carrying its type.
pub fn Component(comptime T: type) type {
    comptime requireStorable(T);
    return struct {
        const Self = @This();

        /// The type this handle stores.
        pub const Type = T;

        id: Entity,

        /// The world that minted this id, checked by every typed operation on `World`.
        ///
        /// Null means "not a world's to mint", and there are exactly two of those: a
        /// pair assembled from two handles, whose id is a function of its halves rather
        /// than a registration, and one of flecs's process-global component ids such as
        /// `EcsRest`. A null is not checked, because there is nothing to check it
        /// against — not because the check is optional.
        world: ?*const c.ecs_world_t = null,

        /// The component as a plain id, for the untyped calls and for pairs.
        pub inline fn asId(self: Self) Id {
            return self.id;
        }

        /// Whether the component holds data. A zero-sized type registers as a tag:
        /// flecs stores nothing for it, and `set` becomes `add`.
        pub inline fn isTag() bool {
            return @sizeOf(T) == 0;
        }
    };
}

/// Options for registering a component.
pub const ComponentDesc = struct {
    /// Defaults to the type's name. flecs treats `.` in a name as a scope separator,
    /// and `@typeName` is full of them, so registration disables that tokenization.
    name: ?[:0]const u8 = null,

    /// Reuse an existing entity as the component, rather than making one.
    entity: Entity = 0,

    /// Store this component in a sparse set instead of in tables. Slower to iterate,
    /// but adding or removing it does not move the entity between tables — which is
    /// what you want for something that changes on many entities every frame.
    sparse: bool = false,

    /// Allow `World.enableComponent` to switch this component off on an entity without
    /// removing it.
    ///
    /// Opt-in because it is not free: flecs keeps a bitset per table for a toggleable
    /// component and consults it on every match. It is also not optional — flecs
    /// refuses `ecs_enable_id` on a component without the trait rather than doing
    /// nothing, so a component that is ever toggled has to be registered saying so.
    can_toggle: bool = false,

    /// Register this component as a singleton: one value, stored on the component
    /// entity itself, which is what the `singleton*` operations on `World` reach.
    ///
    /// The trait is what makes a query term for this component resolve to that one
    /// value rather than to a `$this` the query has to match. Without it the
    /// `singleton*` operations still work — they are the same store — but a query
    /// naming the component matches the component entity like any other entity, which
    /// is almost never what a singleton is written for.
    singleton: bool = false,

    /// Constructor, destructor and copy hooks.
    ///
    /// Null means the ones `typeHooks` derives from `T`, which is the empty set for
    /// plain data and a real lifecycle for a type with a `deinit`. It defaults to null
    /// because the alternative default — none — meant that registering an owning
    /// component the obvious way, `world.component(T, .{})`, silently leaked every value
    /// ever put in it, and nothing said so. Pass `.{}` to register a type with no hooks
    /// deliberately, or a hand-written set to override the derivation.
    hooks: ?c.ecs_type_hooks_t = null,
};

/// Builds the C descriptor for registering `T`. Kept separate from `World` so the
/// naming and sizing rules live next to the type they describe.
pub fn describe(comptime T: type, desc: ComponentDesc) c.ecs_component_desc_t {
    // A tag is size 0 AND alignment 0. Zig reports an alignment of 1 for an empty
    // struct, which is correct for Zig and wrong for flecs: it checks that the two are
    // either both zero or both non-zero, and aborts on the mismatch.
    const size: c.ecs_size_t = @sizeOf(T);
    const alignment: c.ecs_size_t = if (size == 0) 0 else @alignOf(T);

    return .{
        .entity = desc.entity,
        .type = .{
            .size = size,
            .alignment = alignment,
            .hooks = desc.hooks orelse typeHooks(T),
            .component = 0,
            .name = null,
        },
    };
}

/// The name a component is registered under when none is given.
pub fn defaultName(comptime T: type) [:0]const u8 {
    return @typeName(T);
}

test "a zero-sized type is a tag" {
    const Tag = struct {};
    try std.testing.expect(Component(Tag).isTag());

    const Data = struct { x: f32 };
    try std.testing.expect(!Component(Data).isTag());
}

test "the descriptor carries the type's own size and alignment" {
    const Position = struct { x: f32, y: f32 };
    const desc = describe(Position, .{});
    try std.testing.expectEqual(@as(c.ecs_size_t, @sizeOf(Position)), desc.type.size);
    try std.testing.expectEqual(@as(c.ecs_size_t, @alignOf(Position)), desc.type.alignment);
}

test "a tag describes as zero size and zero alignment" {
    // Zig says an empty struct is 1-byte aligned; flecs requires both numbers to be
    // zero for a tag and aborts if only one of them is.
    const Tag = struct {};
    const desc = describe(Tag, .{});
    try std.testing.expectEqual(@as(c.ecs_size_t, 0), desc.type.size);
    try std.testing.expectEqual(@as(c.ecs_size_t, 0), desc.type.alignment);
}

test "a type flecs can align is storable, and one it cannot is not" {
    // Either side of the limit, and the boundary itself. The limit is flecs's — see
    // `max_alignment` — so these are assertions about flecs's storage, not about Zig.
    try std.testing.expect(isStorable(struct { x: f32 }));
    try std.testing.expect(isStorable(u64));
    try std.testing.expect(isStorable(@Vector(4, f32))); // 16
    try std.testing.expect(isStorable(struct { v: f32 align(max_alignment) }));

    try std.testing.expect(!isStorable(struct { v: f32 align(max_alignment * 2) }));
    try std.testing.expect(!isStorable(@Vector(8, f32))); // 32: an AVX register
    try std.testing.expect(!isStorable(@Vector(16, f32))); // 64
}

test "the limit is the one the allocator bridge hands flecs" {
    // Two homes for one number would be the defect this package is most exposed to:
    // `src/os.zig` promises flecs a 16-byte payload and this file refuses anything
    // that needs more, and if the two ever disagreed the refusal would be checking the
    // wrong bound. They are compared rather than kept in step by hand.
    try std.testing.expectEqual(
        @as(usize, max_alignment),
        @import("os.zig").payload_alignment.toByteUnits(),
    );
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
// Copying is where Zig runs out of answers, and where this package used to get it wrong.
// flecs has two copy hooks and uses them for two things a Zig type cannot tell apart:
//
//   `copy`      copy-assign over a live value — what `set` does on a component the
//               entity already has;
//   `copy_ctor` copy into uninitialised memory — what `set` does when it also adds the
//               component, what a DEFERRED `set` does into the command buffer, and what
//               `ecs_clone` and prefab instantiation do into a second entity.
//
// The first three of those hand a value over: the source is a temporary the caller has
// finished with. The last two duplicate: the source stays alive and owned by somebody
// else. Zig has no copy constructor to derive the second from, and flecs calls the same
// pointer for both, so the type has to say which world it lives in — and this package
// has to stop the one it cannot express from happening quietly.
//
//   * A type with `dupe` lives by VALUE. Both hooks duplicate, `set` leaves the caller
//     owning what it passed, and cloning and prefabs work.
//   * A type with `deinit` and no `dupe` is HANDED OVER. Both hooks take the source's
//     bits, `set` gives the value to the world, and duplication is not expressible —
//     so `World.component` marks the component and `World.clone` and prefab
//     instantiation refuse it by name instead of producing two owners of one
//     allocation.
//
// Plain data is neither: with no `deinit` there is nothing to own, a memcpy IS a
// duplicate, and flecs's own empty hook set is already correct.
//=============================================================================

/// flecs's lifecycle hooks for `T`, worked out at compile time.
///
/// A plain-data component gets nothing — the empty hook set, which is what flecs assumes
/// anyway — so this costs nothing to apply to a type that does not need it. It is what
/// `ComponentDesc.hooks` applies by default, so a component with a `deinit` is given its
/// destructor by registration rather than by the caller remembering to ask.
///
/// A component with a `deinit` gets:
///
/// - a destructor that calls it, so removing the component, deleting the entity or
///   destroying the world releases what the value owns;
/// - a constructor, when every field of `T` has a default, so a value flecs creates on
///   its own is `T{}` rather than zeroes. Without one, flecs zeroes the memory;
/// - a copy and a copy-construct, which destroy what the destination held before taking
///   the source. Setting a component twice therefore frees the first value instead of
///   leaking it.
///
/// Which puts one requirement on the type: `deinit` has to be safe to call on a value
/// flecs constructed and nothing has been written to yet — `T{}`, or all zeroes when
/// there is no `T{}` to write. That value is what the copy destroys before it takes the
/// first value a component is ever set to.
///
/// **Adding `dupe` changes what `set` means.** `pub fn dupe(self: T) T` returns an
/// independent copy — a new allocation holding the same contents. With it, both copy
/// hooks duplicate: the world gets its own value and the caller keeps ownership of the
/// one it passed, so `world.set(e, comp, mine)` leaves `mine` for the caller to
/// `deinit`. Without it, `set` hands the value over and the caller must not touch it
/// again. Both are coherent; the type picks one, and `duplicable` reports which.
///
/// `deinit` must take exactly one parameter, the value, and `dupe` exactly one and
/// return `T`. A `deinit` that also wants an allocator — `std.ArrayList`'s, among
/// others — cannot be called from a flecs hook, which is handed nothing but the pointer,
/// so that is a compile error here rather than a surprise later. Wrap such a type in one
/// that remembers its allocator.
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
        // Set explicitly rather than left for flecs to synthesise. flecs's default
        // copy-construct is "run ctor, then run copy" — `flecs_default_copy_ctor`,
        // libs/flecs/flecs.c:21498-21501 — which for the handed-over regime means a
        // fresh value is destroyed and then the source's bits are taken: the same double
        // ownership, arrived at by a longer route. Naming it here is what puts the regime
        // in one place.
        .copy_ctor = &thunks.copyCtor,
    };
}

/// Whether a value of `T` can be duplicated — copied into a second entity while the
/// first keeps its own.
///
/// True for plain data, whose bits ARE the value, and for a type with `dupe`. False for
/// a type that owns something and has not said how to copy it; `World.clone` and prefab
/// instantiation refuse those, because the alternative is two owners of one allocation
/// and nothing that can tell you.
pub fn duplicable(comptime T: type) bool {
    return @sizeOf(T) == 0 or !hasDeinit(T) or hasDupe(T);
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
                to.* = take(value);
            }
        }

        fn copyCtor(
            dst: ?*anyopaque,
            src: ?*const anyopaque,
            count: i32,
            _: ?*const c.ecs_type_info_t,
        ) callconv(.c) void {
            const from: [*]const T = @ptrCast(@alignCast(src.?));
            // The destination is uninitialised, so there is nothing to destroy first.
            for (slice(dst, count), from[0..@intCast(count)]) |*to, *value| {
                to.* = take(value);
            }
        }

        /// One source value, as the type's regime says to take it.
        inline fn take(value: *const T) T {
            return if (comptime hasDupe(T)) value.dupe() else value.*;
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

/// Whether `T` says how to duplicate itself: `pub fn dupe(self: T) T`, or the same taking
/// a pointer.
fn hasDupe(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {},
        else => return false,
    }
    if (!@hasDecl(T, "dupe")) return false;
    const Dupe = @TypeOf(@field(T, "dupe"));
    if (@typeInfo(Dupe) != .@"fn") return false;
    const info = @typeInfo(Dupe).@"fn";
    if (info.params.len != 1 or info.return_type != T) @compileError(
        "zecs cannot derive a copy for " ++ @typeName(T) ++ ": `dupe` has to take the " ++
            "value and nothing else and return " ++ @typeName(T) ++ ", an independent " ++
            "copy the destination will own. A `dupe` that can fail, or that needs an " ++
            "allocator handed to it, cannot be called from a flecs hook — it is given " ++
            "nothing but the two pointers. Wrap the type in one that remembers what it " ++
            "needs.",
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

test "what a type can promise decides which hooks it gets" {
    const Plain = struct { x: f32 };
    try std.testing.expect(duplicable(Plain));
    try std.testing.expect(typeHooks(Plain).dtor == null);
    try std.testing.expect(typeHooks(Plain).copy_ctor == null);

    // Owns something and cannot say how to copy it: handed over, and not duplicable.
    const HandedOver = struct {
        n: u32 = 0,
        pub fn deinit(self: *@This()) void {
            self.n = 0;
        }
    };
    try std.testing.expect(!duplicable(HandedOver));
    try std.testing.expect(typeHooks(HandedOver).dtor != null);
    try std.testing.expect(typeHooks(HandedOver).copy_ctor != null);

    // Says how to copy itself: lives by value, and may be cloned.
    const ByValue = struct {
        n: u32 = 0,
        pub fn deinit(self: *@This()) void {
            self.n = 0;
        }
        pub fn dupe(self: @This()) @This() {
            return .{ .n = self.n };
        }
    };
    try std.testing.expect(duplicable(ByValue));
    try std.testing.expect(typeHooks(ByValue).dtor != null);
    try std.testing.expect(typeHooks(ByValue).copy_ctor != null);

    // A tag has no storage for a hook to act on, and flecs refuses hooks on one.
    const Tag = struct {};
    try std.testing.expect(duplicable(Tag));
    try std.testing.expect(typeHooks(Tag).dtor == null);
}
