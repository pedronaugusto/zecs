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

/// A registered component, carrying its type.
pub fn Component(comptime T: type) type {
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
