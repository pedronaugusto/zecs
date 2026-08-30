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
pub const CacheKind = enum(c.ecs_query_cache_kind_t) {
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

/// Sorting a query's results.
///
/// Sorting is a property of the CACHE, so asking for it makes the query cached whatever
/// `cache_kind` says [read-from-source: `libs/flecs/flecs.c:35949`]. flecs re-sorts when
/// the matched set changes, not on every iteration.
pub const OrderBy = struct {
    /// The component whose values are compared. Zero compares entities alone, and
    /// `compare` is then handed null pointers — which is what `Query.orderByEntity`
    /// builds a comparator for.
    component: Entity = 0,

    /// The comparison. Build one from a Zig function with `Query.orderBy` or
    /// `Query.orderByEntity` rather than writing the C signature out.
    compare: c.ecs_order_by_action_t = null,

    /// Sort a whole table in one call instead of element by element. Optional; flecs
    /// uses its own quicksort over `compare` when this is null.
    sort_table: c.ecs_sort_table_action_t = null,
};

/// Grouping a query's results, so that iteration can be restricted to one group.
///
/// Like sorting, grouping is a property of the cache and makes the query cached.
pub const GroupBy = struct {
    /// The relationship whose target names the group. With no `callback`, flecs uses its
    /// own: the second element of the `(id, *)` pair the table has
    /// [read-from-source: `flecs_query_cache_default_group_by`, `libs/flecs/flecs.c:77861`].
    id: Id = 0,

    /// Derives a group id from a table. Build one with `Query.groupBy`.
    callback: c.ecs_group_by_action_t = null,

    /// Called the first time a group is populated and when it empties, for a per-group
    /// context that `Query.groupInfo` hands back.
    on_create: c.ecs_group_create_action_t = null,
    on_delete: c.ecs_group_delete_action_t = null,

    /// Passed to all three callbacks.
    ctx: ?*anyopaque = null,
    ctx_free: c.ecs_ctx_free_t = null,
};

/// How a query is evaluated, as distinct from what it matches.
///
/// Split out of `QueryDesc` because a typed query takes exactly this and nothing else:
/// its terms come from the spec tuple, so a `terms` field on the type it accepts would
/// be a second way to say the same thing, and the two could disagree. Every option lives
/// here once, and both query forms read it from here.
pub const QueryOptions = struct {
    cache_kind: CacheKind = .default,
    /// `EcsQuery*` flags from the raw layer, for the options with no wrapper yet.
    flags: u32 = 0,
    /// Associate the query with an entity, so it is destroyed along with it.
    entity: Entity = 0,
    /// Context pointer, delivered to callbacks as `Iter.ctx()`.
    ctx: ?*anyopaque = null,

    /// Sort the matched entities. See `OrderBy`.
    order_by: ?OrderBy = null,

    /// Group the matched tables, so iteration can be restricted to one group with
    /// `Query.iterGroup`. See `GroupBy`.
    group_by: ?GroupBy = null,

    /// Fills in the evaluation half of a C descriptor.
    pub fn applyTo(self: QueryOptions, desc: *c.ecs_query_desc_t) void {
        desc.cache_kind = @intFromEnum(self.cache_kind);
        desc.flags = self.flags;
        desc.entity = self.entity;
        desc.ctx = self.ctx;
        if (self.order_by) |o| {
            desc.order_by = o.component;
            desc.order_by_callback = o.compare;
            desc.order_by_table_callback = o.sort_table;
        }
        if (self.group_by) |g| {
            desc.group_by = g.id;
            desc.group_by_callback = g.callback;
            desc.on_group_create = g.on_create;
            desc.on_group_delete = g.on_delete;
            desc.group_by_ctx = g.ctx;
            desc.group_by_ctx_free = g.ctx_free;
        }
    }
};

/// What a query matches, and how it is evaluated.
pub const QueryDesc = struct {
    terms: []const Term = &.{},
    /// A query expression in flecs's DSL, used instead of or alongside `terms`.
    /// Needs the query_dsl addon.
    expr: ?[:0]const u8 = null,
    options: QueryOptions = .{},

    /// Fills in a C descriptor. Public because it is the escape hatch: build one of
    /// these, then set the fields this wrapper does not cover before passing it to
    /// `zecs.c.core.ecs_query_init`.
    pub fn toC(self: QueryDesc) Error!c.ecs_query_desc_t {
        if (self.terms.len > term_count_max) return Error.TooManyTerms;

        var desc = c.ecs_query_desc_t{
            .expr = if (self.expr) |e| e.ptr else null,
        };
        self.options.applyTo(&desc);
        for (self.terms, 0..) |term, i| desc.terms[i] = term.toC();
        return desc;
    }
};

test "term defaults match a zeroed C term" {
    // Field by field rather than byte by byte. `ecs_term_t` has a padding byte between
    // `field_index` and `flags_`, and Zig promises nothing about the contents of
    // padding in a struct literal: in Debug it happened to be zero, and in ReleaseFast
    // it is whatever the stack held — this test read 0x7F there and failed. Padding is
    // not part of the value, so comparing it was testing the compiler rather than the
    // defaults.
    //
    // `inline for` over the C type's own fields, so a field added by a re-vendor is
    // compared without this test being told about it.
    const zeroed = std.mem.zeroes(c.ecs_term_t);
    const built = (Term{}).toC();
    inline for (@typeInfo(c.ecs_term_t).@"struct".fields) |f| {
        try std.testing.expectEqual(@field(zeroed, f.name), @field(built, f.name));
    }
}

test "a query with too many terms is refused rather than truncated" {
    const terms = [_]Term{.{ .id = 1 }} ** (term_count_max + 1);
    try std.testing.expectError(Error.TooManyTerms, (QueryDesc{ .terms = &terms }).toC());
}
