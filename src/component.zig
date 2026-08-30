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
//! one process work.

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
/// on every target this package builds for. `src/memory.zig` holds its own bridge to
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

    /// Constructor, destructor, copy and move hooks. The default — none — is right for
    /// plain data, which is memcpy-able and needs no lifecycle. A component owning a
    /// slice, a file handle or an allocation needs them, and flecs will otherwise copy
    /// it bitwise.
    hooks: c.ecs_type_hooks_t = .{},
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
            .hooks = desc.hooks,
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
    // `src/memory.zig` promises flecs a 16-byte payload and this file refuses anything
    // that needs more, and if the two ever disagreed the refusal would be checking the
    // wrong bound. They are compared rather than kept in step by hand.
    try std.testing.expectEqual(
        @as(usize, max_alignment),
        @import("memory.zig").payload_alignment.toByteUnits(),
    );
}
