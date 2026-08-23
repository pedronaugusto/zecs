//! Memory flecs owns on your behalf: a value of a type it knows about, and the strings
//! it hands back.
//!
//! flecs's reflection layer moves values around without knowing what they are. A value
//! is a pointer plus the entity that describes the type at that pointer, and every
//! operation on one — construct, destruct, copy, move — takes both, plus a world to
//! look the type up in. It is the `void*`-and-a-tag shape in its purest form.
//!
//! Where the Zig type is known at the call site the pair collapses. The pointer is a
//! `*T`, the type entity comes from the same `Component(T)` handle `World.set` uses, and
//! the size flecs works from is whatever it recorded for that component. Nothing here
//! survives to runtime as a wrapper: each of these is one C call with the arguments
//! rearranged.
//!
//! Every operation fails the same way and only that way — the entity handed in as the
//! type is not a type, because it is a tag or a plain entity and flecs has no type info
//! for it. flecs reports that by returning -1 or null in a build with its checks on,
//! and by walking off a null pointer in a build without them.
//!
//! The `_w_type_info` half of this API is left raw. Those functions differ from the
//! ones here only in taking a resolved `ecs_type_info_t*` instead of the entity to
//! resolve, which is a way to hoist the lookup out of a loop rather than a way to say
//! anything more about the type. A second typed spelling of each operation would add
//! surface without adding type information, which is the case against writing it.

const std = @import("std");
const c = @import("c.zig");
const world_mod = @import("world.zig");
const Error = @import("error.zig").Error;

const World = world_mod.World;

/// Constructing, destroying, copying and moving a value of a registered component type.
///
/// A namespace rather than a handle: flecs's value operations all take the pointer and
/// the type separately, and there is nothing worth wrapping them up into that a
/// `Component(T)` and a `*T` do not already say.
pub const Value = struct {
    /// Runs the component's constructor over storage the caller owns.
    ///
    /// The storage may be anything of the right size and alignment — a local, a slot in
    /// an array, an allocation of your own. A component with no constructor hook is
    /// zeroed, which is flecs's rule and not this wrapper's.
    pub inline fn init(world: World, comp: anytype, ptr: *@TypeOf(comp).Type) Error!void {
        if (c.ecs_value_init(world.raw, comp.asId(), ptr) != 0) return Error.NotAType;
    }

    /// Allocates storage from flecs's allocator and constructs a value in it. Release
    /// it with `free`, which destructs before it deallocates.
    pub inline fn new(world: World, comp: anytype) Error!*@TypeOf(comp).Type {
        const ptr = c.ecs_value_new(world.raw, comp.asId()) orelse return Error.NotAType;
        return @ptrCast(@alignCast(ptr));
    }

    /// Runs the component's destructor, leaving the storage itself alone. The
    /// counterpart of `init`.
    pub inline fn fini(world: World, comp: anytype, ptr: *@TypeOf(comp).Type) Error!void {
        if (c.ecs_value_fini(world.raw, comp.asId(), ptr) != 0) return Error.NotAType;
    }

    /// Destructs a value and releases the storage `new` allocated for it.
    pub inline fn free(world: World, comp: anytype, ptr: *@TypeOf(comp).Type) Error!void {
        if (c.ecs_value_free(world.raw, comp.asId(), ptr) != 0) return Error.NotAType;
    }

    /// Copies `src` over `dst`, through the component's copy hook. Both have to be
    /// constructed values already; this is assignment, not construction.
    pub inline fn copy(
        world: World,
        comp: anytype,
        dst: *@TypeOf(comp).Type,
        src: *const @TypeOf(comp).Type,
    ) Error!void {
        if (c.ecs_value_copy(world.raw, comp.asId(), dst, src) != 0) return Error.NotAType;
    }

    /// Moves `src` into `dst` through the component's move hook. `src` is left
    /// constructed but unspecified, and still has to be destructed.
    pub inline fn move(
        world: World,
        comp: anytype,
        dst: *@TypeOf(comp).Type,
        src: *@TypeOf(comp).Type,
    ) Error!void {
        if (c.ecs_value_move(world.raw, comp.asId(), dst, src) != 0) return Error.NotAType;
    }

    /// Moves `src` into raw storage, constructing `dst` in the process. Use this where
    /// `dst` has not been constructed yet; use `move` where it has.
    pub inline fn moveCtor(
        world: World,
        comp: anytype,
        dst: *@TypeOf(comp).Type,
        src: *@TypeOf(comp).Type,
    ) Error!void {
        if (c.ecs_value_move_ctor(world.raw, comp.asId(), dst, src) != 0) return Error.NotAType;
    }
};

/// Releases a string flecs allocated and handed back.
///
/// `Table.str`, `Script.astToString`, `Vars.interpolate` and the rest of flecs's `_str`
/// calls all return heap memory the caller owns. flecs spells this `ecs_os_free`, which
/// is a macro over the OS API's free callback rather than a function, so there is no
/// symbol for the raw layer to declare and this is where it lives instead.
///
/// The callback is whatever was in force when the string was allocated. That is the
/// process-wide OS API, so an allocator installed with `zecs.setAllocator` before the
/// first world is the one that sees it.
pub fn freeString(text: [:0]u8) void {
    const release = c.ecs_os_api.free_ orelse return;
    release(text.ptr);
}
