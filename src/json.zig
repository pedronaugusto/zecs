//! Serializing to JSON and parsing back from it.
//!
//! Needs flecs's `json` addon, which pulls in `meta`: JSON is written from a component's
//! reflection data, so a component with no registered members serializes as an empty
//! object rather than as its fields. Calling anything here from a build without the
//! addon is a compile error rather than an undefined symbol at link time.
//!
//! ## What comes back
//!
//! Every serializer flecs offers returns a `char*` the caller must free with a macro
//! that is not a symbol. That is the whole reason these wrappers exist, and it leaves
//! one decision: what a Zig caller should be handed instead. Three answers were
//! possible and two of them are here.
//!
//! - An `Owned`: the string flecs already built, with its length carried rather than
//!   recomputed, and a `deinit` that `defer` covers. No copy, one thing to remember.
//! - A `*std.Io.Writer`: the same bytes copied once into a buffer, a file or a socket
//!   the caller already has, with nothing owned afterwards. This is the `write*` half
//!   of the module. It is not streaming — flecs assembles the whole document before
//!   any of it is available, and `zecs.strbuf` says why — but it is one copy into the
//!   caller's memory rather than a heap block that outlives the call.
//! - An allocator-copied slice, which is what a binding usually reaches for and is
//!   rejected here: `zecs.setAllocator` already routes flecs's allocations through the
//!   host's allocator, so a copy would be a second block from the same allocator behind
//!   an extra allocator parameter, and would leave the host with two ways to free one
//!   string.
//!
//! ## The descriptors
//!
//! `ecs_entity_to_json_desc_t` and friends are taken raw, by value, so a call reads
//! `.{ .serialize_values = true }` and nothing had to be mirrored. Three of the four
//! are bool fields, an entity and a callback — there is no untyped parameter to remove,
//! no sentinel to translate, nothing to own and no C string to convert, so a Zig mirror
//! would be a second name for the same struct and a second place for a field to be
//! missed when flecs adds one. `ecs_from_json_desc_t` does carry two `char*`, but they
//! are the labels flecs prints in a parse error, and mirroring one descriptor out of
//! four to convert two diagnostic strings is a worse trade than `.ptr` at the call
//! site.
//!
//! What a mirror would have quietly fixed, and what is therefore worth stating instead:
//! **a zeroed descriptor is not flecs's default.** `ECS_ENTITY_TO_JSON_INIT` and
//! `ECS_ITER_TO_JSON_INIT` turn several flags on that `{0}` leaves off, and flecs's own
//! serializers read a null descriptor as "all of them on" — three different meanings
//! for what looks like the same absence of an opinion. `.{}` here is the zeroed one, so
//! `entity_defaults` and `iter_defaults` are provided for the other.

const std = @import("std");
const c = @import("c/json.zig");
const options = @import("zecs_options");
const strbuf = @import("strbuf.zig");
const types = @import("types.zig");
const world_mod = @import("world.zig");
const Error = @import("error.zig").Error;

const Entity = types.Entity;
const World = world_mod.World;

/// A serialized document, owned by the caller. See `zecs.strbuf.Owned`.
pub const Owned = strbuf.Owned;

/// What the `write*` half can fail with: flecs refusing to serialize, or the caller's
/// writer refusing the bytes.
pub const WriteError = Error || std.Io.Writer.Error;

//=============================================================================
// flecs's own descriptor defaults
//
// Written out because a Zig struct literal cannot reach a C macro, and because the
// difference between these and `.{}` is the difference between a document with values
// in it and one with only ids.
//=============================================================================

/// `ECS_ENTITY_TO_JSON_INIT`: what flecs's C users get from the macro, and what a
/// null descriptor means to `ecs_entity_to_json`. Everything else in it is off.
pub const entity_defaults: c.ecs_entity_to_json_desc_t = .{
    .serialize_full_paths = true,
    .serialize_values = true,
};

/// `ECS_ITER_TO_JSON_INIT`. Note `serialize_fields`: without it `serialize_values` has
/// nothing to attach values to, and the results come out as bare entity names.
pub const iter_defaults: c.ecs_iter_to_json_desc_t = .{
    .serialize_values = true,
    .serialize_full_paths = true,
    .serialize_fields = true,
};

/// Every function here calls into the json addon. Saying so at the call site beats an
/// undefined symbol at link time, which is what a build without the addon would
/// otherwise produce.
inline fn requireAddon() void {
    if (comptime !options.addon_json) @compileError(
        "zecs.json needs flecs's json addon: build with -Daddon_json=true, or an " ++
            "addon preset that includes it",
    );
}

/// The tail of every serializer that returns an owned string. `rc` is flecs's zero-is-
/// success return.
inline fn finishOwned(buf: *c.ecs_strbuf_t, rc: c_int) Error!Owned {
    if (rc != 0) {
        // flecs resets the buffer on most of its own failure paths but not on all of
        // them, and resetting one twice is a no-op.
        c.ecs_strbuf_reset(buf);
        return Error.JsonSerializeFailed;
    }
    // A successful serializer always writes at least an empty object, so an empty
    // buffer here means flecs reported success without producing a document.
    return strbuf.take(buf) orelse Error.JsonSerializeFailed;
}

/// The same tail, for the serializers that hand their bytes to a writer.
inline fn finishWrite(buf: *c.ecs_strbuf_t, rc: c_int, out: *std.Io.Writer) WriteError!void {
    if (rc != 0) {
        c.ecs_strbuf_reset(buf);
        return Error.JsonSerializeFailed;
    }
    // `writeInto` resets the buffer whether or not the write lands, so a writer that
    // refuses the bytes costs an error rather than an error and a leak.
    return strbuf.writeInto(buf, out);
}

//=============================================================================
// Serializing
//
// Each operation comes twice: once returning an `Owned`, once writing into a
// `*std.Io.Writer`. Both are built on flecs's `*_buf` entry points, so the two produce
// the same bytes by construction rather than by coincidence.
//=============================================================================

/// Serializes one component value.
///
/// The `void*` and the type id flecs takes separately are one typed pointer here, so
/// the value and the component it is serialized as cannot disagree.
pub inline fn valueToJson(
    world: World,
    comp: anytype,
    value: *const @TypeOf(comp).Type,
) Error!Owned {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishOwned(&buf, c.ecs_ptr_to_json_buf(world.raw, comp.asId(), value, &buf));
}

/// Serializes one component value into `out`.
pub inline fn writeValue(
    out: *std.Io.Writer,
    world: World,
    comp: anytype,
    value: *const @TypeOf(comp).Type,
) WriteError!void {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishWrite(&buf, c.ecs_ptr_to_json_buf(world.raw, comp.asId(), value, &buf), out);
}

/// Serializes an array of component values as a JSON array.
///
/// The count flecs takes alongside the pointer comes from the slice, so the two cannot
/// disagree either.
pub inline fn arrayToJson(
    world: World,
    comp: anytype,
    values: []const @TypeOf(comp).Type,
) Error!Owned {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishOwned(&buf, c.ecs_array_to_json_buf(
        world.raw,
        comp.asId(),
        values.ptr,
        @intCast(values.len),
        &buf,
    ));
}

/// Serializes an array of component values into `out`.
pub inline fn writeArray(
    out: *std.Io.Writer,
    world: World,
    comp: anytype,
    values: []const @TypeOf(comp).Type,
) WriteError!void {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishWrite(&buf, c.ecs_array_to_json_buf(
        world.raw,
        comp.asId(),
        values.ptr,
        @intCast(values.len),
        &buf,
    ), out);
}

/// Serializes a type's structure rather than a value of it: the member names, their
/// types, and their ranges. This is what a remote inspector needs before it can make
/// sense of a value.
///
/// `type_id` is a type entity, which for anything registered through `World.component`
/// is the component's own id.
pub fn typeInfoToJson(world: World, type_id: Entity) Error!Owned {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishOwned(&buf, c.ecs_type_info_to_json_buf(world.raw, type_id, &buf));
}

/// Serializes a type's structure into `out`.
pub fn writeTypeInfo(out: *std.Io.Writer, world: World, type_id: Entity) WriteError!void {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishWrite(&buf, c.ecs_type_info_to_json_buf(world.raw, type_id, &buf), out);
}

/// Serializes one entity: its path, the ids it has, and — with
/// `.{ .serialize_values = true }` — the values behind them.
///
/// A bare `.{}` is the zeroed descriptor and produces ids and nothing else. Pass
/// `entity_defaults` for what a C caller's `ECS_ENTITY_TO_JSON_INIT` would have given.
pub fn entityToJson(world: World, e: Entity, desc: c.ecs_entity_to_json_desc_t) Error!Owned {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishOwned(&buf, c.ecs_entity_to_json_buf(world.raw, e, &buf, &desc));
}

/// Serializes one entity into `out`.
pub fn writeEntity(
    out: *std.Io.Writer,
    world: World,
    e: Entity,
    desc: c.ecs_entity_to_json_desc_t,
) WriteError!void {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishWrite(&buf, c.ecs_entity_to_json_buf(world.raw, e, &buf, &desc), out);
}

/// Serializes the rest of an iteration: every entity the query still has to yield.
///
/// A bare `.{}` yields entity names and no component data — `iter_defaults` is the
/// descriptor that yields values, and `serialize_fields` is the flag people miss.
///
/// **This consumes the iterator.** flecs walks it to the end and releases it, so `it`
/// is spent when this returns and nothing may be read from it afterwards. `it` may be a
/// pointer to a `zecs.Query.Iterator` — in which case its `deinit` is defused here, so
/// the usual `defer it.deinit()` stays correct rather than becoming a double free — or
/// a raw `*ecs_iter_t` for an iteration built through `zecs.c`.
///
/// The iterator a system callback is handed is neither: that iteration belongs to
/// flecs and is already in progress, and taking it over would cost the callback the
/// rows it has not seen yet.
pub fn iterToJson(it: anytype, desc: c.ecs_iter_to_json_desc_t) Error!Owned {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishOwned(&buf, c.ecs_iter_to_json_buf(consume(it), &buf, &desc));
}

/// Serializes the rest of an iteration into `out`. Consumes the iterator — see
/// `iterToJson`.
pub fn writeIter(
    out: *std.Io.Writer,
    it: anytype,
    desc: c.ecs_iter_to_json_desc_t,
) WriteError!void {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishWrite(&buf, c.ecs_iter_to_json_buf(consume(it), &buf, &desc), out);
}

/// Marks an owning iterator as spent and produces the raw iterator flecs serializes.
///
/// The serializer runs the iteration to its end, which is exactly the case
/// `Iterator.finished` exists to record: without this, a `defer it.deinit()` written
/// before the call would release an iterator flecs had already released.
inline fn consume(it: anytype) *c.ecs_iter_t {
    const Pointee = @typeInfo(@TypeOf(it)).pointer.child;
    if (Pointee == c.ecs_iter_t) return it;
    it.finished = true;
    return &it.raw;
}

/// Serializes every entity in the world, in the format `worldFromJson` reads back.
///
/// Builtin entities and modules are left out unless the descriptor asks for them, which
/// is what makes the output a scene rather than a memory dump.
pub fn worldToJson(world: World, desc: c.ecs_world_to_json_desc_t) Error!Owned {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishOwned(&buf, c.ecs_world_to_json_buf(world.raw, &buf, &desc));
}

/// Serializes every entity in the world into `out`.
pub fn writeWorld(
    out: *std.Io.Writer,
    world: World,
    desc: c.ecs_world_to_json_desc_t,
) WriteError!void {
    requireAddon();
    var buf: c.ecs_strbuf_t = .{};
    return finishWrite(&buf, c.ecs_world_to_json_buf(world.raw, &buf, &desc), out);
}

//=============================================================================
// Parsing
//
// flecs's parsers return a pointer into the JSON they were given — the position just
// past what they consumed — or NULL on failure. The pointer is worth keeping: it is
// what lets a caller read a second value out of the same text. It is returned here as
// the remainder of the caller's own slice, which is the same information without the
// pointer arithmetic.
//=============================================================================

/// Parses a JSON value into a component.
///
/// `value` must already be a valid `T`; flecs writes members it finds and leaves the
/// rest alone, so a partial document leaves a partly-updated value rather than a
/// zeroed one.
///
/// Returns what is left of `json` after the value.
pub inline fn valueFromJson(
    world: World,
    comp: anytype,
    value: *@TypeOf(comp).Type,
    json: [:0]const u8,
    desc: c.ecs_from_json_desc_t,
) Error![:0]const u8 {
    requireAddon();
    const rest = c.ecs_ptr_from_json(world.raw, comp.asId(), value, json.ptr, &desc) orelse
        return Error.JsonParseFailed;
    return remainder(json, rest);
}

/// Parses a JSON object of component values onto an existing entity, in the format
/// `entityToJson` produces.
///
/// flecs asserts that the world is not deferred and aborts if it is, so this cannot be
/// called from inside a system or a `deferBegin` block.
///
/// Returns what is left of `json` after the object.
pub fn entityFromJson(
    world: World,
    e: Entity,
    json: [:0]const u8,
    desc: c.ecs_from_json_desc_t,
) Error![:0]const u8 {
    requireAddon();
    const rest = c.ecs_entity_from_json(world.raw, e, json.ptr, &desc) orelse
        return Error.JsonParseFailed;
    return remainder(json, rest);
}

/// Parses a whole world's worth of entities, in the format `worldToJson` produces.
///
/// Returns what is left of `json` after the document.
pub fn worldFromJson(
    world: World,
    json: [:0]const u8,
    desc: c.ecs_from_json_desc_t,
) Error![:0]const u8 {
    requireAddon();
    const rest = c.ecs_world_from_json(world.raw, json.ptr, &desc) orelse
        return Error.JsonParseFailed;
    return remainder(json, rest);
}

/// Loads a world from a JSON file.
///
/// This one returns nothing, unlike the three above, and the reason is a defect in
/// flecs rather than a choice: `ecs_world_from_json_file` reads the file into a buffer,
/// parses it, frees the buffer, and then returns the parse position — which points into
/// the block it just freed. There is nothing safe to hand back, so nothing is.
///
/// A missing file and a malformed one are the same error here, because flecs
/// distinguishes them only by what it logs.
pub fn worldFromJsonFile(
    world: World,
    path: [:0]const u8,
    desc: c.ecs_from_json_desc_t,
) Error!void {
    requireAddon();
    if (c.ecs_world_from_json_file(world.raw, path.ptr, &desc) == null)
        return Error.JsonParseFailed;
}

/// Turns flecs's parse position back into the tail of the caller's slice. The pointer
/// always lands inside `json`, since it is where the parser stopped reading it.
fn remainder(json: [:0]const u8, rest: [*:0]const u8) [:0]const u8 {
    const offset = @intFromPtr(rest) - @intFromPtr(json.ptr);
    std.debug.assert(offset <= json.len);
    return json[offset..];
}

//=============================================================================
// Tests
//
// The behaviour of this module needs a world, components with reflection data, and an
// allocator, so it is exercised end to end in the behaviour suite. What is checked here
// is the part that has no dependencies.
//=============================================================================

test "the parse position comes back as the tail of the caller's slice" {
    const json: [:0]const u8 = "{\"x\": 1} trailing";
    const rest = remainder(json, json.ptr + 8);
    try std.testing.expectEqualStrings(" trailing", rest);
    try std.testing.expectEqual(@as(u8, 0), rest[rest.len]);
}
