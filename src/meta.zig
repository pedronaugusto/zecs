//! Reflection: a flecs schema derived from a Zig type at compile time.
//!
//! flecs's meta addon is how the library learns what is inside a component. Once a type
//! has a schema the Explorer draws it, the JSON serialiser round-trips it, scripts
//! construct it and the REST API edits it live. The C API asks for that schema by hand,
//! one member at a time. Zig already has it: `@typeInfo` knows every field and its type,
//! and `@offsetOf` knows where the field sits. This module hands flecs what the compiler
//! already knows.
//!
//! ```zig
//! const Position = struct { x: f32, y: f32 };
//!
//! const position = try world.component(Position, .{});
//! _ = try zecs.meta.register(world, position);
//! ```
//!
//! Everything that decides the shape of the schema runs at compile time. What is left at
//! runtime is the registration calls themselves, once per type per world.
//!
//! ## Where this hooks in
//!
//! `register` is a second call on an already-registered component rather than a flag on
//! `ComponentDesc`, because reflection is not part of registering a component: it adds
//! entities of its own — one per nested type, one per enum constant — and it needs the
//! component entity to exist before it can name it. Keeping it separate leaves
//! `World.component` a single flecs call, keeps the meta addon off the path of a build
//! that does not want it, and lets a type that is not a component at all still get a
//! schema through `typeId`. It is the same shape flecs's own C API has, where
//! `ecs_struct` takes `.entity = ecs_id(Position)` for a component the caller already
//! registered.
//!
//! What this module does share with `component.zig` is the two rules that must not
//! diverge: `component.defaultName` decides the entity a type is known by, and
//! `component.describe` decides the size and alignment flecs is told. Nested types are
//! registered through both, so a nested type registers identically whether it was
//! reached through `World.component` or through a field of an outer struct.
//!
//! ## What is derived
//!
//! | Zig | flecs |
//! |---|---|
//! | `bool`, `u8`…`u64`, `i8`…`i64`, `f32`, `f64` | the matching primitive |
//! | `[*:0]const u8`, `?[*:0]const u8` | `EcsString` — see the ownership note below |
//! | `struct` | `EcsStruct`, one member per field, offsets from `@offsetOf` |
//! | `enum` | `EcsEnum`, one constant per enumerator, values included |
//! | `packed struct(u32)` of `bool` | `EcsBitmask`, one constant per bit |
//! | `[N]T` | an inline array member, or `EcsArray` when it is a type in its own right |
//!
//! Offsets are passed with `use_offset` set, so flecs records the offset Zig computed
//! instead of recomputing one from member sizes. That is what makes the derived schema
//! agree with the real layout for every struct, including the ones where Zig reorders
//! fields to close a padding hole. Members are emitted in declaration order, which is
//! the order a reader expects to see them in; when Zig has reordered the fields, flecs
//! marks the type `EcsType.partial`, which it records and never acts on.
//!
//! Fields with no storage are not members: a `comptime` field, a zero-sized field, and a
//! field of a zero-sized type are skipped. flecs rejects a member of size zero, and
//! there is nothing to serialise in one.
//!
//! ## What is refused, and why
//!
//! A type this module cannot describe correctly is a `@compileError` naming the type. A
//! schema that is silently wrong is worse than one that does not build: it does not
//! surface until a serialiser walks memory that is not laid out the way it was told.
//!
//! - **Pointers and slices.** flecs has no kind that means "follow this". A slice's
//!   length lives in the slice, where no schema can reach it, and a single pointer gives
//!   a serialiser no way to know whether it owns what it points at. `[*:0]const u8` is
//!   the one exception, because it is exactly the `char*` flecs's `EcsString` already
//!   means.
//! - **Optionals**, other than an optional C string, which has the same layout as the
//!   pointer. flecs has no nullable kind, so `?T` would have to be described as `T` and
//!   would read the payload of an empty optional.
//! - **Unions.** flecs has no tagged-union kind. A union can be described by hand as an
//!   `EcsOpaque` with serialize and ensure_member callbacks, which is what
//!   `zecs.c.core.ecs_opaque_init` is for, but which member is live is a fact only the
//!   containing tag knows and nothing in `@typeInfo` connects the two.
//! - **`@Vector`.** Its `@sizeOf` is rounded up to the hardware's vector width, so the
//!   element count flecs would be told and the bytes the value occupies disagree. `[N]T`
//!   describes the same data with a layout flecs can state exactly.
//! - **Integers of a width flecs has no primitive for** — `u7`, `i24`, `u128`. There is
//!   nothing to map them to, and the nearest primitive would read the wrong bytes.
//! - **`packed struct`** that is not a 32-bit bitmask of `bool`s. flecs models a bitmask
//!   as a 32-bit value and nothing else, and it has no way to describe a field that
//!   occupies part of a byte.
//!
//! An `EcsString` member carries flecs's ownership contract, not Zig's: the JSON reader
//! frees the old value with `ecs_os_free` before storing a copy it made with
//! `ecs_os_malloc`. A member of that type must therefore hold null or a pointer flecs
//! can free. A string the Zig side owns — a literal, an arena — must not be reflected.
//!
//! ## Entity-typed members
//!
//! `zecs.Entity` and `zecs.Id` are `u64`. They are aliases, not distinct types, so
//! nothing in `@typeInfo` separates an entity reference from any other 64-bit integer,
//! and a schema derived from the type alone can only call it `u64`. That is the
//! difference between the Explorer showing a link and showing a number, so a struct can
//! say which of its fields are entities:
//!
//! ```zig
//! const Follows = struct {
//!     target: zecs.Entity,
//!     distance: f32,
//!
//!     pub const zecs_entity_fields = .{"target"};
//! };
//! ```
//!
//! `zecs_id_fields` says the same for members holding a component id or a pair. Both are
//! checked at compile time: a name that is not a field of the struct, or a field that is
//! not 64 bits wide, is a compile error rather than a member flecs will misread. The
//! annotation was chosen over a distinct wrapper type because it changes nothing about
//! the field — code that already treats it as an entity keeps compiling, and adopting
//! reflection stays a one-line change rather than a refactor.
//!
//! ## Registering twice
//!
//! Registration is memoised per world and per type, and the memo is flecs's own: a type
//! that has a schema carries `EcsType`, so the second call sees it and returns. There is
//! no comptime-keyed global, which would be wrong the moment a process has two worlds —
//! ids belong to the world that issued them.
//!
//! A nested type is found by the name `component.defaultName` gives it, which is how
//! `World.component` names it too, so a type used by two components registers once.
//!
//! ## Without the meta addon
//!
//! Calling into this module in a build that left the meta addon out is a compile error
//! rather than a silent no-op. There is no useful weaker behaviour: the reason to call
//! `register` is for something else to read the schema back, and a no-op would leave the
//! Explorer empty and `ecs_ptr_to_json` failing at runtime with nothing pointing at the
//! build option that caused it. The module still compiles in such a build — the gate is
//! inside the functions — so only a caller pays for the mistake.
//!
//! ## Ordering
//!
//! Register schemas outside a deferred block. Building one adds components to entities,
//! and flecs would queue those operations rather than apply them, so nothing would read
//! the schema back until the block ended.

const std = @import("std");
const options = @import("zecs_options");

const c = @import("c/core.zig");
const types = @import("types.zig");
const component_mod = @import("component.zig");
const world_mod = @import("world.zig");

const Entity = types.Entity;
const World = world_mod.World;

/// The package's error set, widened by the one failure this module can observe and the
/// shared set does not name.
pub const Error = @import("error.zig").Error || error{
    /// flecs rejected a derived schema. It logs the reason before returning, so the
    /// detail is on stderr rather than in the error.
    MetaInitFailed,
};

//=============================================================================
// The public surface
//=============================================================================

/// Derives a schema for a registered component and returns the component's entity.
///
/// Safe to call more than once: the second call sees the schema flecs already holds and
/// returns without touching the world.
///
/// This uses the handle's own id rather than looking the type up by name, so a component
/// registered under a `ComponentDesc.name` of its own is still described in place.
pub fn register(world: World, comp: anytype) Error!Entity {
    const id = comp.asId();
    try define(world.raw, @TypeOf(comp).Type, id);
    return id;
}

/// The entity `T` is described by, registering the schema on first use.
///
/// For a primitive this is the type flecs already has — `u32` is flecs's `ecs_u32_t`,
/// not a new entity. For anything else it is the entity `T` registers under, created if
/// this world does not have it yet.
///
/// This is what a component's fields resolve through, and it is the id to hand to
/// `zecs.c.core.ecs_ptr_to_json` and friends for a type that is not a component.
pub fn typeId(world: World, comptime T: type) Error!Entity {
    return typeEntity(world.raw, T);
}

//=============================================================================
// Deriving the schema
//
// Everything below decides its shape at compile time and leaves only the registration
// calls at runtime.
//=============================================================================

fn typeEntity(world: *c.ecs_world_t, comptime T: type) Error!Entity {
    // Guarded here as well as in `define`, because this is the half `typeId` reaches
    // first: a primitive's entity is a linked symbol the meta addon defines, and
    // `EcsType` below is another, so both are gone from a build without it.
    if (comptime !options.addon_meta) @compileError(
        "zecs.meta needs flecs's meta addon, which this build left out. " ++
            "Build zecs with -Daddon_meta, or with an addon preset that includes it.",
    );

    if (comptime primitiveOf(T)) |p| return p.builtinId();

    const name = comptime component_mod.defaultName(T);
    const e = c.ecs_entity_init(world, &.{
        // Same rules as `World.component`: the name comes from `@typeName` and is full
        // of dots, and an empty separator is what stops flecs reading it as a path.
        .name = name.ptr,
        .sep = "",
        .use_low_id = true,
    });
    if (e == 0) return Error.EntityInitFailed;

    if (c.ecs_has_id(world, e, c.FLECS_IDEcsTypeID_)) return e;

    // The size and alignment have to be flecs's before the schema is: `flecs_init_type`
    // treats a type that is already a component as authoritative and checks its own
    // computation against it, and treats one that is not as a runtime type whose layout
    // it is free to decide.
    var desc = component_mod.describe(T, .{});
    desc.entity = e;
    if (c.ecs_component_init(world, &desc) == 0) return Error.ComponentInitFailed;

    try define(world, T, e);
    return e;
}

fn define(world: *c.ecs_world_t, comptime T: type, e: Entity) Error!void {
    if (comptime !options.addon_meta) @compileError(
        "zecs.meta needs flecs's meta addon, which this build left out. " ++
            "Build zecs with -Daddon_meta, or with an addon preset that includes it.",
    );

    if (c.ecs_has_id(world, e, c.FLECS_IDEcsTypeID_)) return;

    switch (comptime shapeOf(T)) {
        // A zero-sized type is a tag. flecs stores nothing for it and refuses a schema
        // of size zero, and there would be nothing in it to describe.
        .tag => {},
        .primitive => |p| {
            if (c.ecs_primitive_init(world, &.{
                .entity = e,
                .kind = @intFromEnum(p),
            }) == 0) return Error.MetaInitFailed;
        },
        .structure => try defineStruct(world, T, e),
        .enumeration => try defineEnum(world, T, e),
        .bitmask => try defineBitmask(world, T, e),
        .array => try defineArray(world, T, e),
    }
}

fn defineStruct(world: *c.ecs_world_t, comptime T: type, e: Entity) Error!void {
    const list = comptime members(T);

    // Every member's type is resolved before any member is added, because each addition
    // makes flecs recompute the whole struct and it reads the size of every member type
    // it has been given so far.
    var member_types: [list.len]Entity = undefined;
    inline for (list, 0..) |m, i| {
        member_types[i] = switch (m.present) {
            .derived => try typeEntity(world, m.Elem),
            .entity => Primitive.entity.builtinId(),
            .id => Primitive.id.builtinId(),
        };
    }

    inline for (list, 0..) |m, i| {
        const member: c.ecs_member_t = .{
            .name = m.name.ptr,
            .type = member_types[i],
            .count = m.count,
            .offset = m.offset,
            // Without this flecs lays the struct out itself from member sizes, and any
            // disagreement with Zig's layout becomes a serialiser reading the wrong
            // bytes. `use_offset` is how flecs is told the offset is already known; it
            // is a separate flag because an offset of zero is a real offset.
            .use_offset = true,
        };
        if (c.ecs_struct_add_member(world, e, &member) != 0) return Error.MetaInitFailed;
    }
}

fn defineEnum(world: *c.ecs_world_t, comptime E: type, e: Entity) Error!void {
    const Storage = EnumStorage(E);
    const underlying = (comptime enumPrimitive(E)).builtinId();

    var data: c.EcsEnum = .{ .underlying_type = underlying };
    c.ecs_set_id(world, e, c.FLECS_IDEcsEnumID_, @sizeOf(c.EcsEnum), &data);

    // Constants are set through the `(Constant, underlying)` pair rather than through
    // `ecs_enum_init`, which reads a zero in its descriptor as "no value given" and
    // auto-numbers the constant instead. A Zig enum with a zero enumerator that is not
    // its lowest would otherwise be given a value it does not have.
    inline for (@typeInfo(E).@"enum".fields) |field| {
        const constant = c.ecs_entity_init(world, &.{
            .name = field.name.ptr,
            .parent = e,
            .sep = "",
        });
        if (constant == 0) return Error.EntityInitFailed;

        var value: Storage = @intCast(field.value);
        c.ecs_set_id(
            world,
            constant,
            c.ecs_pair(c.EcsConstant, underlying),
            @sizeOf(Storage),
            &value,
        );
    }
}

fn defineBitmask(world: *c.ecs_world_t, comptime T: type, e: Entity) Error!void {
    const list = comptime bitmaskConstants(T);

    var desc: c.ecs_bitmask_desc_t = .{ .entity = e };
    inline for (list, 0..) |constant, i| {
        desc.constants[i] = .{ .name = constant.name.ptr, .value = constant.value };
    }
    if (c.ecs_bitmask_init(world, &desc) == 0) return Error.MetaInitFailed;
}

fn defineArray(world: *c.ecs_world_t, comptime T: type, e: Entity) Error!void {
    const info = @typeInfo(T).array;
    const elem = try typeEntity(world, info.child);
    if (c.ecs_array_init(world, &.{
        .entity = e,
        .type = elem,
        .count = info.len,
    }) == 0) return Error.MetaInitFailed;
}

//=============================================================================
// The compile-time half
//=============================================================================

/// How a member is presented, where the Zig type alone does not say.
const Present = enum { derived, entity, id };

/// One member of a derived struct schema.
const Member = struct {
    name: [:0]const u8,
    /// The member's type, or the element type when `count` is non-zero.
    Elem: type,
    /// Elements in an inline array member. Zero for a scalar member, which is what
    /// flecs reads as "one".
    count: i32,
    offset: i32,
    present: Present,
};

/// The members of `T`, in declaration order.
fn members(comptime T: type) []const Member {
    comptime {
        checkAnnotations(T);

        var list: []const Member = &.{};
        for (@typeInfo(T).@"struct".fields) |field| {
            // A comptime field is a value the type carries, not storage in it.
            if (field.is_comptime) continue;
            // flecs rejects a member of size zero, and a field with no storage has
            // nothing to serialise.
            if (@sizeOf(field.type) == 0) continue;

            const Elem = ElementOf(field.type);
            if (@sizeOf(Elem) == 0) @compileError(
                "zecs.meta cannot describe field '" ++ field.name ++ "' of " ++
                    @typeName(T) ++ ": an array of the zero-sized type " ++
                    @typeName(Elem) ++ " has no element flecs can measure",
            );

            list = list ++ [_]Member{.{
                .name = field.name,
                .Elem = Elem,
                .count = countOf(field.type),
                .offset = @offsetOf(T, field.name),
                .present = presentOf(T, field.name),
            }};
        }
        return list;
    }
}

fn ElementOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .array => |a| a.child,
        else => T,
    };
}

fn countOf(comptime T: type) i32 {
    return switch (@typeInfo(T)) {
        .array => |a| a.len,
        else => 0,
    };
}

fn presentOf(comptime T: type, comptime name: []const u8) Present {
    if (@hasDecl(T, "zecs_entity_fields")) {
        inline for (T.zecs_entity_fields) |listed| {
            if (comptime std.mem.eql(u8, listed, name)) return .entity;
        }
    }
    if (@hasDecl(T, "zecs_id_fields")) {
        inline for (T.zecs_id_fields) |listed| {
            if (comptime std.mem.eql(u8, listed, name)) return .id;
        }
    }
    return .derived;
}

/// Checks `zecs_entity_fields` and `zecs_id_fields` against the type they annotate, so
/// a renamed field is a compile error rather than an annotation that stops applying.
fn checkAnnotations(comptime T: type) void {
    comptime {
        for (.{ "zecs_entity_fields", "zecs_id_fields" }) |decl| {
            if (!@hasDecl(T, decl)) continue;
            for (@field(T, decl)) |name| {
                if (!@hasField(T, name)) @compileError(
                    @typeName(T) ++ "." ++ decl ++ " names '" ++ name ++
                        "', which is not a field of it",
                );
                const Elem = ElementOf(@FieldType(T, name));
                if (Elem != Entity) @compileError(
                    @typeName(T) ++ "." ++ decl ++ " names '" ++ name ++
                        "', which is a " ++ @typeName(Elem) ++ " rather than a " ++
                        @typeName(Entity),
                );
            }
        }
    }
}

/// One constant of a derived bitmask.
const Constant = struct {
    name: [:0]const u8,
    value: c.ecs_flags64_t,
};

/// The set bits of a packed struct, one constant per `bool` field.
fn bitmaskConstants(comptime T: type) []const Constant {
    comptime {
        if (@bitSizeOf(T) != 32) @compileError(
            "zecs.meta cannot describe " ++ @typeName(T) ++
                " as a bitmask: flecs models a bitmask as a 32-bit value and nothing " ++
                "else, and this one is " ++ std.fmt.comptimePrint("{d}", .{@bitSizeOf(T)}) ++
                " bits wide. Declare it as `packed struct(u32)`.",
        );

        var list: []const Constant = &.{};
        for (@typeInfo(T).@"struct".fields) |field| {
            // A field named with a leading underscore is padding by convention: it is
            // there to make the backing integer come out the right width. flecs has no
            // way to name a run of unclaimed bits, so it is left out of the schema, and
            // a value with any of those bits set will not serialise.
            if (field.name[0] == '_') continue;

            if (field.type != bool) @compileError(
                "zecs.meta cannot describe " ++ @typeName(T) ++ " as a bitmask: field '" ++
                    field.name ++ "' is a " ++ @typeName(field.type) ++
                    " rather than a bool, and flecs has no kind for a field that " ++
                    "occupies part of a byte. Name it with a leading underscore if it " ++
                    "is padding.",
            );

            list = list ++ [_]Constant{.{
                .name = field.name,
                .value = @as(c.ecs_flags64_t, 1) << @bitOffsetOf(T, field.name),
            }};
        }

        if (list.len == 0) @compileError(
            "zecs.meta cannot describe " ++ @typeName(T) ++
                " as a bitmask: it has no bool fields",
        );
        return list;
    }
}

/// What flecs will be told `T` is.
const Shape = union(enum) {
    primitive: Primitive,
    structure,
    enumeration,
    bitmask,
    array,
    tag,
};

fn shapeOf(comptime T: type) Shape {
    if (@sizeOf(T) == 0) return .tag;
    // Forced to comptime so the branch that refuses a type is not analysed for one that
    // was accepted here: `refuse` is a `@compileError`, and a runtime `if` would reach
    // it on the way past.
    if (comptime primitiveOf(T)) |p| return .{ .primitive = p };

    return switch (@typeInfo(T)) {
        .@"struct" => |s| switch (s.layout) {
            // A packed struct is a bag of bits. The only bag flecs has a kind for is a
            // 32-bit set of flags, and `bitmaskConstants` says so if this is not one.
            .@"packed" => .bitmask,
            else => .structure,
        },
        .@"enum" => .enumeration,
        .array => .array,
        else => refuse(T),
    };
}

fn refuse(comptime T: type) noreturn {
    const prefix = "zecs.meta cannot derive a schema for " ++ @typeName(T) ++ ": ";
    @compileError(prefix ++ switch (@typeInfo(T)) {
        .pointer => "flecs's reflection has no kind that means \"follow this\". A " ++
            "slice's length is in the slice, where a schema cannot reach it, and a " ++
            "single pointer tells a serialiser nothing about who owns the target. " ++
            "`[*:0]const u8` is the exception, because that is flecs's own string type. " ++
            "For anything else, describe it by hand with zecs.c.core.ecs_opaque_init.",
        .optional => "flecs's reflection has no nullable kind, so this would have to " ++
            "be described as its payload and would be read even when it is empty. " ++
            "`?[*:0]const u8` is the exception, because a null pointer is how flecs " ++
            "spells an absent string.",
        .@"union" => "flecs's reflection has no tagged-union kind, and nothing in " ++
            "@typeInfo connects a bare union to the tag that says which member is " ++
            "live. Describe it by hand with zecs.c.core.ecs_opaque_init, or split it into " ++
            "a tag component and a struct.",
        .vector => "@sizeOf rounds a vector up to the hardware's width, so the bytes " ++
            "it occupies and the elements a schema would claim disagree. Use [N]T, " ++
            "whose layout flecs can state exactly.",
        .int => "flecs has no primitive of that width. Widen it to one of 8, 16, 32 " ++
            "or 64 bits.",
        .float => "flecs has no primitive of that width. Use f32 or f64.",
        else => "flecs's reflection has no kind for it.",
    });
}

//=============================================================================
// Primitives
//=============================================================================

/// flecs's primitive kinds, with flecs's own values.
const Primitive = enum(c.ecs_primitive_kind_t) {
    boolean = 1,
    char,
    byte,
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    uptr,
    iptr,
    string,
    entity,
    id,

    /// The entity flecs registered this primitive under. These are library globals
    /// assigned when the meta module is imported, so they are a load rather than a
    /// constant.
    fn builtinId(self: Primitive) Entity {
        return switch (self) {
            .boolean => c.FLECS_IDecs_bool_tID_,
            .char => c.FLECS_IDecs_char_tID_,
            .byte => c.FLECS_IDecs_byte_tID_,
            .u8 => c.FLECS_IDecs_u8_tID_,
            .u16 => c.FLECS_IDecs_u16_tID_,
            .u32 => c.FLECS_IDecs_u32_tID_,
            .u64 => c.FLECS_IDecs_u64_tID_,
            .i8 => c.FLECS_IDecs_i8_tID_,
            .i16 => c.FLECS_IDecs_i16_tID_,
            .i32 => c.FLECS_IDecs_i32_tID_,
            .i64 => c.FLECS_IDecs_i64_tID_,
            .f32 => c.FLECS_IDecs_f32_tID_,
            .f64 => c.FLECS_IDecs_f64_tID_,
            .uptr => c.FLECS_IDecs_uptr_tID_,
            .iptr => c.FLECS_IDecs_iptr_tID_,
            .string => c.FLECS_IDecs_string_tID_,
            .entity => c.FLECS_IDecs_entity_tID_,
            .id => c.FLECS_IDecs_id_tID_,
        };
    }
};

/// The flecs primitive `T` is, or null when it is not one.
fn primitiveOf(comptime T: type) ?Primitive {
    if (isCString(T)) return .string;
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int => |i| switch (i.bits) {
            8 => if (i.signedness == .signed) .i8 else .u8,
            16 => if (i.signedness == .signed) .i16 else .u16,
            32 => if (i.signedness == .signed) .i32 else .u32,
            64 => if (i.signedness == .signed) .i64 else .u64,
            else => null,
        },
        .float => |f| switch (f.bits) {
            32 => .f32,
            64 => .f64,
            else => null,
        },
        else => null,
    };
}

/// Whether `T` is the `char*` flecs's string primitive means. Spelled as a set of type
/// comparisons rather than as a walk over `@typeInfo`, because that set is the whole of
/// what has the right layout.
fn isCString(comptime T: type) bool {
    return T == [*:0]const u8 or T == [*:0]u8 or
        T == ?[*:0]const u8 or T == ?[*:0]u8;
}

/// The primitive an enum's values are stored as.
///
/// Zig picks the narrowest tag type that fits — `enum { a, b, c }` is backed by a `u2` —
/// while flecs's primitives are whole bytes. The primitive is chosen by the enum's
/// in-memory size rather than by its tag's bit width, which is the number that decides
/// what a serialiser reads; Zig zero-extends the tag into that space when it stores one.
fn enumPrimitive(comptime E: type) Primitive {
    const signed = @typeInfo(@typeInfo(E).@"enum".tag_type).int.signedness == .signed;
    return switch (@sizeOf(E)) {
        1 => if (signed) .i8 else .u8,
        2 => if (signed) .i16 else .u16,
        4 => if (signed) .i32 else .u32,
        8 => if (signed) .i64 else .u64,
        else => @compileError(
            "zecs.meta cannot derive a schema for " ++ @typeName(E) ++
                ": flecs has no primitive that is " ++
                std.fmt.comptimePrint("{d}", .{@sizeOf(E)}) ++ " bytes wide",
        ),
    };
}

/// The integer an enum's constants are written to flecs as. Matches `enumPrimitive`.
fn EnumStorage(comptime E: type) type {
    const signed = @typeInfo(@typeInfo(E).@"enum".tag_type).int.signedness == .signed;
    return switch (@sizeOf(E)) {
        1 => if (signed) i8 else u8,
        2 => if (signed) i16 else u16,
        4 => if (signed) i32 else u32,
        8 => if (signed) i64 else u64,
        else => unreachable,
    };
}

//=============================================================================
// Tests
//
// These check the compile-time half, which is where every decision about a schema is
// made. That the schema flecs ends up holding is the right one is checked from the
// outside, in the behaviour tests, by serialising a value through it.
//=============================================================================

test "a struct's members carry the offsets Zig computed" {
    const Position = struct { x: f32, y: f32 };
    const list = comptime members(Position);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("x", list[0].name);
    try std.testing.expectEqual(@as(i32, @offsetOf(Position, "x")), list[0].offset);
    try std.testing.expectEqualStrings("y", list[1].name);
    try std.testing.expectEqual(@as(i32, @offsetOf(Position, "y")), list[1].offset);
}

test "offsets follow the layout even when Zig reorders the fields" {
    // Zig is free to move `wide` ahead of `narrow` to close the padding hole. The
    // offsets have to be the ones the compiler chose, whatever order they come out in.
    const Mixed = struct { narrow: u8, wide: u64, also_narrow: u8 };
    const list = comptime members(Mixed);

    try std.testing.expectEqual(@as(i32, @offsetOf(Mixed, "narrow")), list[0].offset);
    try std.testing.expectEqual(@as(i32, @offsetOf(Mixed, "wide")), list[1].offset);
    try std.testing.expectEqual(@as(i32, @offsetOf(Mixed, "also_narrow")), list[2].offset);
    // Declaration order is what the members are emitted in, not memory order.
    try std.testing.expectEqualStrings("narrow", list[0].name);
    try std.testing.expectEqualStrings("wide", list[1].name);
}

test "fields with no storage are not members" {
    const Tag = struct {};
    const Sparse = struct {
        comptime label: u32 = 7,
        nothing: Tag,
        void_field: void,
        value: i32,
    };
    const list = comptime members(Sparse);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("value", list[0].name);
}

test "an array field becomes an inline array member of its element type" {
    const Hand = struct { cards: [5]i32, count: u8 };
    const list = comptime members(Hand);

    try std.testing.expectEqual(@as(i32, 5), list[0].count);
    try std.testing.expectEqual(i32, list[0].Elem);
    // A scalar member is count zero, which flecs reads as one element.
    try std.testing.expectEqual(@as(i32, 0), list[1].count);
}

test "an array of arrays keeps the inner array as the element type" {
    const Grid = struct { rows: [2][3]f32 };
    const list = comptime members(Grid);

    try std.testing.expectEqual(@as(i32, 2), list[0].count);
    try std.testing.expectEqual([3]f32, list[0].Elem);
}

test "annotated fields are presented as entities and ids" {
    const Follows = struct {
        target: Entity,
        rel: types.Id,
        distance: f32,

        pub const zecs_entity_fields = .{"target"};
        pub const zecs_id_fields = .{"rel"};
    };
    const list = comptime members(Follows);

    try std.testing.expectEqual(Present.entity, list[0].present);
    try std.testing.expectEqual(Present.id, list[1].present);
    try std.testing.expectEqual(Present.derived, list[2].present);
}

test "every integer and float width flecs has maps to its primitive" {
    try std.testing.expectEqual(Primitive.boolean, primitiveOf(bool).?);
    try std.testing.expectEqual(Primitive.u8, primitiveOf(u8).?);
    try std.testing.expectEqual(Primitive.i16, primitiveOf(i16).?);
    try std.testing.expectEqual(Primitive.u32, primitiveOf(u32).?);
    try std.testing.expectEqual(Primitive.i64, primitiveOf(i64).?);
    try std.testing.expectEqual(Primitive.f32, primitiveOf(f32).?);
    try std.testing.expectEqual(Primitive.f64, primitiveOf(f64).?);
    try std.testing.expectEqual(Primitive.string, primitiveOf([*:0]const u8).?);
    try std.testing.expectEqual(Primitive.string, primitiveOf(?[*:0]const u8).?);

    // An entity is a u64 and nothing in the type says otherwise, so a struct
    // has to name the fields it means as entities.
    try std.testing.expectEqual(Primitive.u64, primitiveOf(Entity).?);

    // Widths flecs has no primitive for are not primitives, and `shapeOf` refuses them.
    try std.testing.expect(primitiveOf(u7) == null);
    try std.testing.expect(primitiveOf(f16) == null);
}

test "an enum's primitive follows its size, not its tag's bit width" {
    // Zig backs this with a u2 and stores it in a byte.
    const Small = enum { a, b, c };
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Small));
    try std.testing.expectEqual(Primitive.u8, enumPrimitive(Small));
    try std.testing.expectEqual(u8, EnumStorage(Small));

    const Signed = enum(i32) { down = -1, level = 0, up = 1 };
    try std.testing.expectEqual(Primitive.i32, enumPrimitive(Signed));
    try std.testing.expectEqual(i32, EnumStorage(Signed));

    const Wide = enum(u64) { big = std.math.maxInt(u64) };
    try std.testing.expectEqual(Primitive.u64, enumPrimitive(Wide));
}

test "a packed struct of bools becomes one constant per bit" {
    const Flags = packed struct(u32) {
        visible: bool,
        frozen: bool,
        selected: bool,
        _rest: u29,
    };
    const list = comptime bitmaskConstants(Flags);

    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("visible", list[0].name);
    try std.testing.expectEqual(@as(u64, 1), list[0].value);
    try std.testing.expectEqual(@as(u64, 2), list[1].value);
    try std.testing.expectEqual(@as(u64, 4), list[2].value);
}

test "shapes are what flecs will be told" {
    const Position = struct { x: f32, y: f32 };
    const Flags = packed struct(u32) { on: bool, _rest: u31 };
    const Tag = std.meta.Tag(Shape);
    const tagOf = struct {
        fn f(comptime T: type) Tag {
            return comptime shapeOf(T);
        }
    }.f;

    try std.testing.expectEqual(Tag.structure, tagOf(Position));
    try std.testing.expectEqual(Tag.enumeration, tagOf(enum { a, b }));
    try std.testing.expectEqual(Tag.bitmask, tagOf(Flags));
    try std.testing.expectEqual(Tag.array, tagOf([4]f32));
    try std.testing.expectEqual(Tag.tag, tagOf(struct {}));
    try std.testing.expectEqual(Tag.primitive, tagOf(f32));
    try std.testing.expectEqual(Primitive.f32, (comptime shapeOf(f32)).primitive);
}
