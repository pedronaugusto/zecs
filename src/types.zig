//! The vocabulary the typed layer is built from: ids, terms, and the enums flecs
//! expresses as bare integers.
//!
//! Every enum here is `enum(i16)` or similar with flecs's own values, and the ABI test
//! checks those values against the header — so they are exactly as fast as the integers
//! they replace, and mistyping one is a compile error instead of a silently wrong query.

const std = @import("std");
const c = @import("c/core.zig");
const Error = @import("error.zig").Error;

/// An entity. Also an id: in flecs every entity can be used as a component or a tag,
/// and every component is an entity. Kept as a plain integer rather than a handle
/// struct so that arrays of entities are arrays of integers, and so that the pair
/// arithmetic flecs relies on keeps working.
pub const Entity = c.ecs_entity_t;

/// An id: an entity, or a relationship pair, optionally with flags set.
pub const Id = c.ecs_id_t;

/// Maximum terms in a query, as this build was configured.
pub const term_count_max = c.FLECS_TERM_COUNT_MAX;

/// Maximum events an observer can watch, as this build was configured.
pub const event_count_max = c.FLECS_EVENT_DESC_MAX;

//=============================================================================
// Traversal flags
//
// Set on a term's source to say where the term looks for its data. Combine with `|`.
//=============================================================================

/// Match the entity itself. The default when no traversal flag is set.
pub const Self = c.EcsSelf;
/// Follow `trav` upwards — for `ChildOf`, that means "or any ancestor".
pub const Up = c.EcsUp;
/// Traverse, without matching self.
pub const Trav = c.EcsTrav;
/// Like `Up`, but sorts results so parents are iterated before their children.
pub const Cascade = c.EcsCascade;
/// With `Cascade`, reverse the order.
pub const Desc = c.EcsDesc;

//=============================================================================
// Term enums
//=============================================================================

/// How a term accesses what it matches. Affects scheduling: two systems that only read
/// the same component can run at the same time.
pub const InOut = enum(i16) {
    /// InOut for regular terms, In for shared ones.
    default = c.EcsInOutDefault,
    /// Not accessed at all. The term still constrains matching.
    none = c.EcsInOutNone,
    /// Not accessed and not part of the field list.
    filter = c.EcsInOutFilter,
    read_write = c.EcsInOut,
    read = c.EcsIn,
    write = c.EcsOut,
};

/// How a term combines with the ones around it.
pub const Oper = enum(i16) {
    /// The entity must match this term.
    all = c.EcsAnd,
    /// The entity must match at least one term in the `any` run.
    any = c.EcsOr,
    /// The entity must not match this term.
    not = c.EcsNot,
    /// The entity may match. The field is empty when it does not — check `isSet`.
    optional = c.EcsOptional,
    all_from = c.EcsAndFrom,
    any_from = c.EcsOrFrom,
    not_from = c.EcsNotFrom,
};

/// Whether a query keeps a cache of the tables it matches. Caching costs memory and
/// makes matching nearly free; uncached queries are cheap to create and slower to run.
pub const CacheKind = enum(c_uint) {
    /// Cached for queries owned by an entity (systems, observers), uncached otherwise.
    default = c.EcsQueryCacheDefault,
    /// Cache the terms that can be cached.
    auto = c.EcsQueryCacheAuto,
    /// Require that every term is cacheable.
    all = c.EcsQueryCacheAll,
    none = c.EcsQueryCacheNone,
};

//=============================================================================
// Builtin entities
//
// These are variables in the library rather than compile-time constants — their values
// are assigned when a world is created — so they cannot be plain declarations here.
// An enum with a resolver keeps them typed and greppable, and costs a load.
//=============================================================================

pub const Builtin = enum {
    // Relationships
    child_of,
    is_a,
    depends_on,
    slot_of,

    // Wildcards
    wildcard,
    any,
    this_entity,
    variable,

    // Traits
    prefab,
    disabled,
    empty,
    transitive,
    final,
    exclusive,
    traversable,
    sparse,
    on_instantiate,
    override,
    inherit,
    dont_inherit,

    // Identifiers
    name,
    symbol,

    // Events
    on_add,
    on_remove,
    on_set,
    monitor,
    on_table_create,
    on_delete,

    // Pipeline phases
    pre_frame,
    on_load,
    post_load,
    pre_update,
    on_update,
    on_validate,
    post_update,
    pre_store,
    on_store,
    post_frame,
    phase,

    /// The entity flecs assigned to this concept in the current process.
    pub inline fn id(self: Builtin) Entity {
        return switch (self) {
            .child_of => c.EcsChildOf,
            .is_a => c.EcsIsA,
            .depends_on => c.EcsDependsOn,
            .slot_of => c.EcsSlotOf,

            .wildcard => c.EcsWildcard,
            .any => c.EcsAny,
            .this_entity => c.EcsThis,
            .variable => c.EcsVariable,

            .prefab => c.EcsPrefab,
            .disabled => c.EcsDisabled,
            .empty => c.EcsEmpty,
            .transitive => c.EcsTransitive,
            .final => c.EcsFinal,
            .exclusive => c.EcsExclusive,
            .traversable => c.EcsTraversable,
            .sparse => c.EcsSparse,
            .on_instantiate => c.EcsOnInstantiate,
            .override => c.EcsOverride,
            .inherit => c.EcsInherit,
            .dont_inherit => c.EcsDontInherit,

            .name => c.EcsName,
            .symbol => c.EcsSymbol,

            .on_add => c.EcsOnAdd,
            .on_remove => c.EcsOnRemove,
            .on_set => c.EcsOnSet,
            .monitor => c.EcsMonitor,
            .on_table_create => c.EcsOnTableCreate,
            .on_delete => c.EcsOnDelete,

            .pre_frame => c.EcsPreFrame,
            .on_load => c.EcsOnLoad,
            .post_load => c.EcsPostLoad,
            .pre_update => c.EcsPreUpdate,
            .on_update => c.EcsOnUpdate,
            .on_validate => c.EcsOnValidate,
            .post_update => c.EcsPostUpdate,
            .pre_store => c.EcsPreStore,
            .on_store => c.EcsOnStore,
            .post_frame => c.EcsPostFrame,
            .phase => c.EcsPhase,
        };
    }
};

//=============================================================================
// Strings flecs hands back
//=============================================================================

/// Returns a block flecs allocated to the allocator it came from, via the OS API's own
/// free callback.
///
/// flecs frees these with `ecs_os_free`, which is not a symbol: it is a macro over the
/// free pointer in the process-wide OS API, so a block has to go back through the same
/// table entry it came out of. `Str.deinit`, `strbuf.free` and `value.freeString` are the
/// three owning types that hand a caller one of these strings, and all three release it
/// through this one function rather than each repeating the same unwrap.
///
/// Null only in a process where flecs has never had an OS API, which is a process that
/// cannot have produced the block being freed.
pub fn freeOsBlock(ptr: ?*anyopaque) void {
    const free = c.ecs_os_api.free_ orelse return;
    free(ptr);
}

/// A string flecs allocated and the caller has to free.
///
/// Handing back a bare slice would leave the caller to discover that `ecs_os_free` is a
/// macro rather than a symbol, and `std.mem.Allocator.free` on one of these is a
/// corrupted heap rather than an error, so the answer is carried with the string instead.
pub const Str = struct {
    /// The text, without its terminator. Valid until `deinit`.
    value: [:0]const u8,

    /// Returns the block to the allocator flecs made it from.
    pub fn deinit(self: Str) void {
        freeOsBlock(@ptrCast(@constCast(self.value.ptr)));
    }

    /// Takes ownership of a `char*` flecs returned. Null stays null: flecs renders an
    /// empty result as no string at all rather than as an empty one.
    pub fn take(raw: ?[*:0]u8) ?Str {
        return .{ .value = std.mem.span(raw orelse return null) };
    }
};

//=============================================================================
// Pairs
//=============================================================================

/// The id of a relationship pair, `(first, second)`.
pub inline fn pair(first: Entity, second: Entity) Id {
    return c.ecs_pair(first, second);
}

/// The relationship of a pair.
pub inline fn pairFirst(id: Id) Entity {
    return c.ECS_PAIR_FIRST(id);
}

/// The target of a pair.
pub inline fn pairSecond(id: Id) Entity {
    return c.ECS_PAIR_SECOND(id);
}

/// Whether an id is a relationship pair rather than a plain component.
pub inline fn isPair(id: Id) bool {
    return c.ECS_IS_PAIR(id);
}

//=============================================================================
// Terms
//=============================================================================

/// One side of a term: which entity, or which query variable, it refers to.
pub const TermRef = struct {
    /// An entity, or traversal flags, or both. `.{ .id = Up }` reads "the nearest
    /// ancestor that has this component", with the relationship given by `Term.trav`.
    id: Entity = 0,
    /// A name to resolve instead of an id. Query variables are written `"$name"`.
    name: ?[:0]const u8 = null,

    fn toC(self: TermRef) c.ecs_term_ref_t {
        return .{
            .id = self.id,
            .name = if (self.name) |n| n.ptr else null,
        };
    }
};

/// One condition in a query.
///
/// The common case is just an id: `.{ .id = position.asId() }`. The rest exists for
/// traversal, optional terms, relationship wildcards and access annotations.
pub const Term = struct {
    /// The component, tag or pair to match.
    id: Id = 0,
    /// Where to look for it. Defaults to the matched entity.
    src: TermRef = .{},
    /// For pairs built from parts rather than an id.
    first: TermRef = .{},
    second: TermRef = .{},
    /// The relationship to follow when `src` asks for traversal. `ChildOf` unless the
    /// relationship says otherwise.
    trav: Entity = 0,
    inout: InOut = .default,
    oper: Oper = .all,

    fn toC(self: Term) c.ecs_term_t {
        return .{
            .id = self.id,
            .src = self.src.toC(),
            .first = self.first.toC(),
            .second = self.second.toC(),
            .trav = self.trav,
            .inout = @intFromEnum(self.inout),
            .oper = @intFromEnum(self.oper),
        };
    }
};

/// What a query matches, and how it is evaluated.
pub const QueryDesc = struct {
    terms: []const Term = &.{},
    /// A query expression in flecs's DSL, used instead of or alongside `terms`.
    /// Needs the query_dsl addon.
    expr: ?[:0]const u8 = null,
    cache_kind: CacheKind = .default,
    /// `EcsQuery*` flags from the raw layer, for the options with no wrapper yet.
    flags: u32 = 0,
    /// Associate the query with an entity, so it is destroyed along with it.
    entity: Entity = 0,
    /// Context pointer, delivered to callbacks as `Iter.ctx()`.
    ctx: ?*anyopaque = null,

    /// Fills in a C descriptor. Public because it is the escape hatch: build one of
    /// these, then set the fields this wrapper does not cover before passing it to
    /// `zecs.c.core.ecs_query_init`.
    pub fn toC(self: QueryDesc) Error!c.ecs_query_desc_t {
        if (self.terms.len > term_count_max) return Error.TooManyTerms;

        var desc = c.ecs_query_desc_t{
            .expr = if (self.expr) |e| e.ptr else null,
            .cache_kind = @intFromEnum(self.cache_kind),
            .flags = self.flags,
            .entity = self.entity,
            .ctx = self.ctx,
        };
        for (self.terms, 0..) |term, i| desc.terms[i] = term.toC();
        return desc;
    }
};

test "term defaults match a zeroed C term" {
    const zeroed = std.mem.zeroes(c.ecs_term_t);
    const built = (Term{}).toC();
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&zeroed),
        std.mem.asBytes(&built),
    );
}

test "a query with too many terms is refused rather than truncated" {
    const terms = [_]Term{.{ .id = 1 }} ** (term_count_max + 1);
    try std.testing.expectError(Error.TooManyTerms, (QueryDesc{ .terms = &terms }).toC());
}
