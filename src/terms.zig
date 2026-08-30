//! The list a typed query is built from — and the only list.
//!
//! A flecs query is a list of terms, and iterating one reads its results back by FIELD
//! INDEX. Writing the two out separately is what this module exists to stop: a term list
//! in one place and `it.fieldSelf(Position, 0)` in another are two spellings of the same
//! ordering, and nothing checks that they agree. They agree until a term is inserted,
//! and then the loop reads a different component of the same size — which is not a crash,
//! it is wrong numbers.
//!
//! Here the terms and the reads come from one tuple. The term list is built from it, the
//! row type is derived from it, and the field indices are computed from it and then
//! CHECKED against the query flecs compiled (`checkLayout`, asserted at construction and
//! tested below). The type of each slice comes from the `Component(T)` handle that
//! produced the term, so a size-compatible mix-up is a compile error rather than a
//! silent reinterpretation.
//!
//! ```zig
//! const q = try world.queryOf(.{ position, zecs.in(velocity) }, .{});
//! defer q.deinit();
//!
//! var it = q.iter();
//! defer it.deinit();
//! while (it.next()) |row| {
//!     const p, const v = row.fields;   // []Position, []const Velocity
//!     for (p, v) |*pos, vel| pos.x += vel.x * row.it.deltaTime();
//! }
//! ```
//!
//! **What the typed form does not cover.** Terms that traverse (`Up`, `Cascade`), name a
//! source or a query variable, or join into an `Or` chain change where a field's data
//! comes from or which field index it lands on, and the derivation above assumes neither
//! happens. Asking for one here is a compile error naming the raw path rather than a
//! quietly wrong slice: `World.query` with an explicit `terms` list still expresses
//! everything flecs can express, and `Iter.field` sizes a traversed field correctly.

const std = @import("std");
const c = @import("c/core.zig");
const types = @import("types.zig");
const iter_mod = @import("iter.zig");

const Entity = types.Entity;
const Id = types.Id;
const Iter = iter_mod.Iter;

/// A term's access and operator, for the entries of a typed spec that need something
/// other than "match it, read and write it".
pub const TermOptions = struct {
    /// Defaults to flecs's `InOutDefault`, which for a term matched on the entity
    /// itself means read-write.
    inout: types.InOut = .default,
    oper: types.Oper = .all,
};

/// An id used as a term without a Zig type behind it: a tag built at runtime, a
/// relationship pair, a builtin. It constrains matching and yields no field.
pub const RawId = struct {
    /// `Component(T)` names its payload the same way, which is what lets one derivation
    /// walk handles and raw ids together. `void` is how "no payload" is spelled.
    pub const Type = void;

    id: Id,

    pub inline fn asId(self: RawId) Id {
        return self.id;
    }
};

/// One entry of a spec tuple, once an option other than the default is wanted.
///
/// A spec entry that is a bare `Component(T)` handle is read as
/// `.{ .inout = .default, .oper = .all }`; everything else is one of these.
///
/// Each marker comes in two spellings that are the SAME type: `Marked(H, opts)` and its
/// named forms `In`, `Out`, `Optional`, `Without` name the type, for writing a spec's
/// type down at container scope; `term`, `in`, `out`, `optional`, `without` build a
/// value of it. A callback's parameter type is written with the first and the spec is
/// built with the second, and they cannot drift because there is one definition.
pub fn Marked(comptime Handle: type, comptime opts: TermOptions) type {
    return struct {
        /// Recognised by `Spec` — a plain handle has no such declaration.
        pub const zecs_term_marker: TermOptions = opts;
        pub const Wrapped = Handle;

        handle: Handle,
    };
}

/// Read-only access. Two systems that only read the same component may run at the same
/// time, so this is not only a `const` on the slice.
pub fn In(comptime Handle: type) type {
    return Marked(Handle, .{ .inout = .read });
}

/// Write-only access. The field is still a slice; the annotation is what flecs schedules
/// on, and it also keeps the term out of change detection's read set.
pub fn Out(comptime Handle: type) type {
    return Marked(Handle, .{ .inout = .write });
}

/// An optional term. Its row element is `?[]T`: null for the tables that did not have it.
pub fn Optional(comptime Handle: type) type {
    return Marked(Handle, .{ .oper = .optional });
}

/// Match only entities that do NOT have this. Yields no row element.
pub fn Without(comptime Handle: type) type {
    return Marked(Handle, .{ .inout = .none, .oper = .not });
}

/// Constrain on a raw id — a pair, a builtin, a tag registered at runtime. Yields no row
/// element, because there is no Zig type to give one.
pub const WithId = Marked(RawId, .{ .inout = .none });

/// The same, negated.
pub const WithoutId = Marked(RawId, .{ .inout = .none, .oper = .not });

/// A term with explicit access and operator.
pub fn term(handle: anytype, comptime opts: TermOptions) Marked(@TypeOf(handle), opts) {
    return .{ .handle = handle };
}

pub fn in(handle: anytype) In(@TypeOf(handle)) {
    return .{ .handle = handle };
}

pub fn out(handle: anytype) Out(@TypeOf(handle)) {
    return .{ .handle = handle };
}

pub fn optional(handle: anytype) Optional(@TypeOf(handle)) {
    return .{ .handle = handle };
}

pub fn without(handle: anytype) Without(@TypeOf(handle)) {
    return .{ .handle = handle };
}

pub fn withId(id: Id) WithId {
    return .{ .handle = .{ .id = id } };
}

pub fn withoutId(id: Id) WithoutId {
    return .{ .handle = .{ .id = id } };
}

/// What one entry of the spec resolved to. Comptime only.
const Entry = struct {
    /// Index of this entry in the spec tuple, which is also its term index and — once
    /// `checkLayout` has agreed with flecs — its field index.
    index: comptime_int,
    /// The component's payload type. `void` for a raw id.
    Payload: type,
    opts: TermOptions,
    /// Whether the entry produces a slice in the row.
    data: bool,
};

/// The derivation. `Tuple` is the type of the spec tuple, so everything below is settled
/// at compile time; the ids themselves are runtime values read off the handles.
pub fn Spec(comptime Tuple: type) type {
    const info = @typeInfo(Tuple);
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError(
        "a query spec is a tuple of component handles, such as " ++
            "`.{ position, zecs.in(velocity) }`; got " ++ @typeName(Tuple),
    );
    const fields = info.@"struct".fields;
    if (fields.len == 0) @compileError("a query spec needs at least one term");
    if (fields.len > types.term_count_max) @compileError(std.fmt.comptimePrint(
        "a query spec has {d} terms and this flecs build allows {d}",
        .{ fields.len, types.term_count_max },
    ));

    comptime var entries: [fields.len]Entry = undefined;
    comptime var row_types: [fields.len]type = undefined;
    comptime var row_len: comptime_int = 0;
    // Which spec entry each row element came from, so the row builder and `each` walk
    // the same mapping the row type was built from.
    comptime var row_entry: [fields.len]comptime_int = undefined;

    inline for (fields, 0..) |f, i| {
        const opts: TermOptions = if (@hasDecl(f.type, "zecs_term_marker"))
            f.type.zecs_term_marker
        else
            .{};
        const Handle = if (@hasDecl(f.type, "zecs_term_marker")) f.type.Wrapped else f.type;
        if (!@hasDecl(Handle, "Type") or !@hasDecl(Handle, "asId")) @compileError(
            "a query spec entry is a component handle, a raw id from `zecs.withId`, or " ++
                "one of those wrapped by `zecs.in` / `out` / `optional` / `without`; " ++
                "entry " ++ std.fmt.comptimePrint("{d}", .{i}) ++ " is " ++ @typeName(f.type),
        );
        switch (opts.oper) {
            .all, .not, .optional => {},
            .any, .all_from, .any_from, .not_from => @compileError(
                "`" ++ @tagName(opts.oper) ++ "` changes which field index a term lands " ++
                    "on — an Or chain shares one field between several terms — so the " ++
                    "typed spec cannot derive the row from it. Build the query with " ++
                    "`World.query` and an explicit `terms` list, and read the fields " ++
                    "with `Iter.field`.",
            ),
        }
        const Payload = Handle.Type;
        const data = @sizeOf(Payload) != 0 and
            opts.oper != .not and
            opts.inout != .none and
            opts.inout != .filter;

        entries[i] = .{ .index = i, .Payload = Payload, .opts = opts, .data = data };
        if (data) {
            const Elem = if (opts.inout == .read) []const Payload else []Payload;
            row_types[row_len] = if (opts.oper == .optional) ?Elem else Elem;
            row_entry[row_len] = i;
            row_len += 1;
        }
    }

    // Frozen into consts before the type below closes over them: a generated type may not
    // capture a reference to a `comptime var`.
    const frozen_entries = entries;
    const frozen_row_entry = row_entry;
    const frozen_row_types = row_types;
    const data_count = row_len;

    return struct {
        const Self = @This();

        /// One term per tuple entry, in order.
        pub const term_count: i8 = fields.len;

        /// The slices one matched table yields, in spec order with the non-data entries
        /// left out. A tuple, so `const p, const v = row.fields;` destructures it.
        pub const Row = std.meta.Tuple(frozen_row_types[0..data_count]);

        /// Pointers to one entity's components, in the same order as `Row`, as `each`
        /// passes them.
        pub const Refs = blk: {
            var t: [data_count]type = undefined;
            for (frozen_row_entry[0..data_count], 0..) |e, k| {
                const entry = frozen_entries[e];
                const P = if (entry.opts.inout == .read)
                    *const entry.Payload
                else
                    *entry.Payload;
                t[k] = if (entry.opts.oper == .optional) ?P else P;
            }
            break :blk std.meta.Tuple(&t);
        };

        /// The terms, built from the handles the caller passed. Runtime, because the ids
        /// are runtime: a component is registered into a world, not into the program.
        pub fn build(spec: Tuple) [fields.len]types.Term {
            var out_terms: [fields.len]types.Term = undefined;
            inline for (frozen_entries, 0..) |entry, i| {
                const field = spec[i];
                const handle = if (@hasDecl(@TypeOf(field), "zecs_term_marker"))
                    field.handle
                else
                    field;
                out_terms[i] = .{
                    .id = handle.asId(),
                    .inout = entry.opts.inout,
                    .oper = entry.opts.oper,
                };
            }
            return out_terms;
        }

        /// Whether the query flecs compiled has the layout this derivation assumed: one
        /// field per term, in order.
        ///
        /// flecs assigns `field_index` per term and only merges indices across an `Or`
        /// chain [read-from-source: `libs/flecs/flecs.c:38607`-`38612`], which the
        /// comptime refusal above rules out — so the assumption is `field_index == i`.
        /// It is asserted at construction rather than trusted, because it is the one
        /// place this module's derivation touches flecs's.
        pub fn checkLayout(q: *const c.ecs_query_t) bool {
            if (q.term_count != term_count) return false;
            const compiled = q.terms orelse return false;
            inline for (frozen_entries, 0..) |_, i| {
                if (compiled[i].field_index != @as(i8, @intCast(i))) return false;
            }
            return true;
        }

        /// The typed slices for the table the iterator is positioned on.
        pub fn row(it: Iter) Row {
            var r: Row = undefined;
            inline for (frozen_row_entry[0..data_count], 0..) |e, k| {
                const entry = frozen_entries[e];
                const index: i8 = @intCast(entry.index);
                // `[]T` coerces to `[]const T`, so a read-only term's slice arrives const
                // without a second accessor: the constness is in `Row`, and the accessor
                // is the same one every other term uses.
                if (entry.opts.oper == .optional) {
                    r[k] = it.field(entry.Payload, index);
                } else {
                    r[k] = it.fieldSelf(entry.Payload, index);
                }
            }
            return r;
        }

        /// Pointers into `r` for the entity at `offset` within the table.
        pub fn refs(r: Row, offset: usize) Refs {
            var out_refs: Refs = undefined;
            inline for (frozen_row_entry[0..data_count], 0..) |e, k| {
                const entry = frozen_entries[e];
                if (entry.opts.oper == .optional) {
                    out_refs[k] = if (r[k]) |slice| &slice[offset] else null;
                } else {
                    out_refs[k] = &r[k][offset];
                }
            }
            return out_refs;
        }

        /// What `each` calls its body with: the caller's context, the entity, then one
        /// pointer per data term in `Row` order. Built here rather than at the call site
        /// so that the argument order and the row order are the same derivation.
        pub fn Args(comptime Ctx: type) type {
            comptime var t: [data_count + 2]type = undefined;
            t[0] = Ctx;
            t[1] = Entity;
            inline for (@typeInfo(Refs).@"struct".fields, 0..) |f, k| t[2 + k] = f.type;
            const frozen = t;
            return std.meta.Tuple(&frozen);
        }

        pub fn args(ctx: anytype, e: Entity, r: Row, offset: usize) Args(@TypeOf(ctx)) {
            var a: Args(@TypeOf(ctx)) = undefined;
            a[0] = ctx;
            a[1] = e;
            const rf = refs(r, offset);
            inline for (0..data_count) |k| a[2 + k] = rf[k];
            return a;
        }
    };
}

/// One matched table, typed.
///
/// `it` is the untyped iterator, for the delta time, the entities and everything the
/// typed row does not carry; `fields` is the tuple of slices, in spec order.
pub fn TypedRow(comptime S: type) type {
    return struct {
        const Self = @This();

        /// The spec this row was derived from, so a caller holding only the row can name
        /// the types in it.
        pub const spec = S;

        it: Iter,
        fields: S.Row,

        /// Entities in this table, in the same order as every slice in `fields`.
        pub inline fn entities(self: Self) []const Entity {
            return self.it.entities();
        }

        pub inline fn count(self: Self) usize {
            return self.it.count();
        }

        pub inline fn deltaTime(self: Self) c.ecs_ftime_t {
            return self.it.deltaTime();
        }

        /// Calls `body(ctx, entity, ptr...)` once per entity in this table.
        ///
        /// The per-table loop above is the faster shape and the reason an archetype ECS
        /// is worth having; this is for the bodies that genuinely need one entity at a
        /// time, and it costs nothing extra — the pointers are computed from slices the
        /// row already holds. `ctx` is whatever the body needs and may be `{}`.
        pub inline fn each(self: Self, ctx: anytype, comptime body: anytype) void {
            const ents = self.entities();
            for (ents, 0..) |e, k| {
                @call(.auto, body, S.args(ctx, e, self.fields, k));
            }
        }
    };
}

/// A typed row for the spec `Tuple` describes. Sugar, so a callback's parameter can be
/// written without naming `Spec` in between.
pub fn RowOf(comptime Tuple: type) type {
    return TypedRow(Spec(Tuple));
}

/// Turns a Zig function over typed rows into the C callback flecs stores on a system or
/// an observer.
///
/// The counterpart to `iter_mod.callback`, which hands the body an untyped `Iter` and
/// leaves it to pick the field indices out by hand. Here the terms the system was built
/// with and the fields the body reads come from the same `Tuple`, and the layout
/// assumption is asserted against the query flecs compiled on every call — compiled out
/// in ReleaseFast, like every other `std.debug.assert` in this package.
///
/// ```zig
/// const spec = .{ position, zecs.in(velocity) };
///
/// fn move(row: zecs.RowOf(@TypeOf(spec))) void {
///     const p, const v = row.fields;
///     for (p, v) |*pos, vel| pos.x += vel.x * row.deltaTime();
/// }
///
/// _ = try world.system(.{
///     .name = "Move",
///     .phase = zecs.Builtin.on_update.id(),
///     .query = .{ .terms = &zecs.SpecOf(@TypeOf(spec)).build(spec) },
///     .callback = zecs.rowCallback(@TypeOf(spec), move),
/// });
/// ```
pub fn rowCallback(
    comptime Tuple: type,
    comptime handler: fn (row: RowOf(Tuple)) void,
) c.ecs_iter_action_t {
    const S = Spec(Tuple);
    return &struct {
        fn thunk(raw: *c.ecs_iter_t) callconv(.c) void {
            const it = Iter{ .raw = raw };
            // The one assumption the derivation makes, checked against the query this
            // callback was actually attached to rather than against the one the spec was
            // used to build. A system whose terms were written out by hand and whose
            // callback came from here would be caught right here.
            std.debug.assert(raw.query == null or S.checkLayout(raw.query.?));
            handler(.{ .it = it, .fields = S.row(it) });
        }
    }.thunk;
}

test "a spec derives its row from the handles, and only from them" {
    const zecs = @import("zecs.zig");

    const world = try zecs.World.init();
    defer world.deinit();

    const Position = struct { x: f32 = 0, y: f32 = 0 };
    const Velocity = struct { x: f32 = 0, y: f32 = 0 };
    const Tag = struct {};

    const position = try world.component(Position, .{});
    const velocity = try world.component(Velocity, .{});
    const tag = try world.component(Tag, .{});

    const spec = .{ position, in(velocity), tag };
    const S = Spec(@TypeOf(spec));

    // Three terms, two of which carry data: a zero-sized component is a constraint.
    try std.testing.expectEqual(@as(i8, 3), S.term_count);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(S.Row).@"struct".fields.len);
    try std.testing.expectEqual([]Position, @typeInfo(S.Row).@"struct".fields[0].type);
    try std.testing.expectEqual([]const Velocity, @typeInfo(S.Row).@"struct".fields[1].type);

    const built = S.build(spec);
    try std.testing.expectEqual(position.asId(), built[0].id);
    try std.testing.expectEqual(types.InOut.default, built[0].inout);
    try std.testing.expectEqual(velocity.asId(), built[1].id);
    try std.testing.expectEqual(types.InOut.read, built[1].inout);
    try std.testing.expectEqual(tag.asId(), built[2].id);
}

test "flecs numbers the fields the way the derivation assumed" {
    // The one assumption this module makes about flecs, checked against flecs rather
    // than against the comment that states it.
    const zecs = @import("zecs.zig");

    const world = try zecs.World.init();
    defer world.deinit();

    const A = struct { v: u64 = 0 };
    const B = struct { v: u32 = 0 };
    const C = struct { v: u8 = 0 };

    const a = try world.component(A, .{});
    const b = try world.component(B, .{});
    const cc = try world.component(C, .{});

    // A negated term and an optional one both take a field index of their own, which is
    // what makes `field_index == term index` hold for everything the typed spec allows.
    const spec = .{ a, without(b), optional(cc) };
    const S = Spec(@TypeOf(spec));
    const built = S.build(spec);

    const q = try world.query(.{ .terms = &built });
    defer q.deinit();

    try std.testing.expect(S.checkLayout(q.raw));
}
