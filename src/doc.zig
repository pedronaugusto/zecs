//! Documentation strings on entities: what an inspector displays next to an id.
//!
//! Needs flecs's `doc` addon. Calling anything here from a build without it is a
//! compile error rather than an undefined symbol at link time.
//!
//! flecs offers six setters and six getters, one pair per kind of string. They differ
//! only in which tag the string is stored under, so what is here is one setter and one
//! getter over a `Kind` enum rather than twelve near-identical wrappers. That keeps the
//! part worth getting right — the conversion between a C string and a Zig slice — in
//! one place instead of twelve, and it is the same set of operations spelled
//! `zecs.doc.set(world, e, .brief, "...")`.
//!
//! ## Ownership
//!
//! Nothing here is owned by the caller and nothing here needs freeing, but the two
//! directions borrow differently.
//!
//! A string passed to `set` is copied immediately, by the component's copy hook, so the
//! caller's buffer is free the moment the call returns. A string returned by `get`
//! points into flecs's own copy and is valid until that string is set again or removed,
//! until the entity is deleted, or until the world is destroyed — whichever comes
//! first.

const std = @import("std");
const c = @import("c.zig");
const options = @import("zecs_options");
const types = @import("types.zig");
const world_mod = @import("world.zig");

const Entity = types.Entity;
const World = world_mod.World;

/// Which documentation string. Each is a separate `(EcsDocDescription, tag)` pair on
/// the entity, so setting one leaves the others alone.
pub const Kind = enum {
    /// A display name, free of the constraints a real entity name has: it need not be
    /// unique among siblings and may contain anything, including the separators a path
    /// would choke on.
    ///
    /// The one asymmetric kind. `get(.name)` falls back to the entity's actual name
    /// when no doc name was set, so it answers for almost every named entity, and the
    /// string it returns then belongs to the entity's name rather than to its
    /// documentation. `set(world, e, .name, null)` removes the doc name and returns
    /// `get` to that fallback rather than to null.
    name,
    /// One line, for a tooltip or a list.
    brief,
    /// The long form.
    detail,
    /// A URL.
    link,
    /// A display colour, in whatever notation the consumer of it expects — flecs
    /// stores the string and does not interpret it.
    color,
    /// A stable identifier for the entity, for a tool that has to recognise it across
    /// runs. Entity ids are not that: they are recycled.
    uuid,
};

/// Every function here calls into the doc addon.
inline fn requireAddon() void {
    if (comptime !options.addon_doc) @compileError(
        "zecs.doc needs flecs's doc addon: build with -Daddon_doc=true, or an addon " ++
            "preset that includes it",
    );
}

/// Sets one of an entity's documentation strings, or removes it when `value` is null.
///
/// The string is copied, so `value` need not outlive the call.
pub inline fn set(world: World, e: Entity, kind: Kind, value: ?[:0]const u8) void {
    requireAddon();
    const ptr: ?[*:0]const u8 = if (value) |v| v.ptr else null;
    switch (kind) {
        .name => c.ecs_doc_set_name(world.raw, e, ptr),
        .brief => c.ecs_doc_set_brief(world.raw, e, ptr),
        .detail => c.ecs_doc_set_detail(world.raw, e, ptr),
        .link => c.ecs_doc_set_link(world.raw, e, ptr),
        .color => c.ecs_doc_set_color(world.raw, e, ptr),
        .uuid => c.ecs_doc_set_uuid(world.raw, e, ptr),
    }
}

/// Reads one of an entity's documentation strings, or null when it has none.
///
/// The slice borrows flecs's copy — see the module comment for how long it lasts — and
/// carries its sentinel, so it can be handed back to a C API without a second copy.
pub inline fn get(world: World, e: Entity, kind: Kind) ?[:0]const u8 {
    requireAddon();
    const raw = switch (kind) {
        .name => c.ecs_doc_get_name(world.raw, e),
        .brief => c.ecs_doc_get_brief(world.raw, e),
        .detail => c.ecs_doc_get_detail(world.raw, e),
        .link => c.ecs_doc_get_link(world.raw, e),
        .color => c.ecs_doc_get_color(world.raw, e),
        .uuid => c.ecs_doc_get_uuid(world.raw, e),
    } orelse return null;
    return std.mem.span(raw);
}
