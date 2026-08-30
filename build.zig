const std = @import("std");

/// The package manifest, imported so the version has one home.
///
/// `zecs.version` used to be a second copy of the number in `build.zig.zon`, kept in
/// step by remembering to. It is now derived: this build reads the manifest and passes
/// the string through the options module, and `src/zecs.zig` parses it at compile time.
const manifest = @import("build.zig.zon");

//=============================================================================
// Addons
//=============================================================================

/// Every optional flecs addon, named as flecs names it.
///
/// The `FLECS_<NAME>` define each one maps to is derived from the tag name, so this
/// enum is the only place an addon has to be listed: the option, the C define and the
/// value reported back to Zig all come from here.
pub const Addon = enum {
    alerts,
    app,
    doc,
    exclusive_access,
    journal,
    json,
    http,
    log,
    meta,
    metrics,
    module,
    os_api_impl,
    perf_trace,
    pipeline,
    rest,
    parser,
    query_dsl,
    script,
    script_math,
    system,
    stats,
    timer,
    units,
};

/// Named starting points for the addon set. Individual `-Daddon_<name>` options are
/// layered on top of whichever is chosen.
pub const AddonPreset = enum {
    /// Everything upstream enables when `FLECS_CUSTOM_BUILD` is left undefined, which
    /// is upstream's own default. `FLECS_CPP` is the one omission: it exists for the
    /// C++ API and this package compiles flecs as C.
    full,
    /// Every addon this package knows about, including the four upstream leaves out of
    /// its own default build. This is the configuration the ABI manifest is generated
    /// against, because it is the only one whose header declares every flecs symbol.
    everything,
    /// Storage, queries and the OS API implementation. Nothing else. A starting point
    /// for builds that name exactly what they need.
    minimal,
};

fn presetHas(preset: AddonPreset, addon: Addon) bool {
    return switch (preset) {
        // Upstream's default block, minus FLECS_CPP. The four addons excluded here are
        // excluded upstream too: journal, perf_trace, script_math and exclusive_access
        // are opt-in even in a full build.
        .full => switch (addon) {
            .exclusive_access, .journal, .perf_trace, .script_math => false,
            else => true,
        },
        .everything => true,
        // The OS API implementation is kept because without it flecs has no threads,
        // no mutexes and no clock, and `ecs_set_threads` cannot work.
        .minimal => addon == .os_api_impl,
    };
}

/// "os_api_impl" -> "FLECS_OS_API_IMPL"
fn addonDefine(comptime addon: Addon) []const u8 {
    return "FLECS_" ++ comptime blk: {
        const name = @tagName(addon);
        var upper: [name.len]u8 = undefined;
        for (name, 0..) |ch, i| upper[i] = std.ascii.toUpper(ch);
        const frozen = upper;
        break :blk &frozen;
    };
}

/// "os_api_impl" -> "addon_os_api_impl"
fn addonOption(comptime addon: Addon) []const u8 {
    return "addon_" ++ @tagName(addon);
}

//=============================================================================
// Scalar precision
//=============================================================================

pub const Precision = enum {
    fp32,
    fp64,

    fn ctype(self: Precision) []const u8 {
        return switch (self) {
            .fp32 => "float",
            .fp64 => "double",
        };
    }
};

/// flecs's internal checking level. `auto` is the only default that cannot be wrong:
/// it follows `-Doptimize`, rather than the mode the build runner itself was compiled
/// in, which is a different thing entirely and not what anyone means.
pub const DebugChecks = enum {
    auto,
    none,
    debug,
    sanitize,

    fn resolve(self: DebugChecks, optimize: std.builtin.OptimizeMode) DebugChecks {
        if (self != .auto) return self;
        return if (optimize == .Debug) .sanitize else .none;
    }
};

//=============================================================================
// The preprocessor state, as one value
//
// Every macro that reaches the C compiler is collected here first, and each consumer
// derives what it needs from the same list: the library's `-D` flags, the include-path
// macros the ABI guard's `@cImport` is preprocessed with, and the translate-c step the
// ABI manifest is generated from.
//
// This matters more than it looks. `FLECS_SANITIZE` adds two fields to `ecs_vec_t` and
// `FLECS_DEBUG` adds one to `ecs_ref_t`; `ecs_ftime_t` changes width; `FLECS_TERM_COUNT_MAX`
// changes the width of four fields in `ecs_iter_t`. A guard that preprocessed the header
// differently from the library would be checking a struct nobody compiled.
//=============================================================================

const Macro = struct {
    name: []const u8,
    /// `null` for a bare `#define NAME`, which is what flecs's feature flags are.
    value: ?[]const u8 = null,
};

const Macros = struct {
    list: []const Macro,
    /// Zig defines `NDEBUG` for C code in every release mode. When flecs checks are
    /// asked for anyway, it has to come back off — see the comment where this is set.
    undef_ndebug: bool,

    /// Flags for `addCSourceFile`.
    fn cFlags(self: Macros, b: *std.Build) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        out.append(b.allocator, "-std=c99") catch @panic("OOM");
        for (self.list) |m| {
            out.append(b.allocator, if (m.value) |v|
                b.fmt("-D{s}={s}", .{ m.name, v })
            else
                b.fmt("-D{s}", .{m.name})) catch @panic("OOM");
        }
        if (self.undef_ndebug) out.append(b.allocator, "-UNDEBUG") catch @panic("OOM");
        return out.toOwnedSlice(b.allocator) catch @panic("OOM");
    }

    /// The same state, applied to a Zig module so that any `@cImport` inside it
    /// preprocesses the header exactly as the library was compiled.
    ///
    /// With one exception, which is worth stating precisely because it is the only
    /// place the guard's view and the library's can differ. `-UNDEBUG` is not applied:
    /// `zig test` takes no `-U`, and `std.Build.Module` has `addCMacro` with no
    /// counterpart that undefines. So in a release build that asked for flecs checks,
    /// the header the guard reads still has `NDEBUG` set while the library's did not.
    ///
    /// That divergence is provably layout-neutral. Every conditional field in flecs.h
    /// is guarded by `FLECS_DEBUG` or `FLECS_SANITIZE` — `ecs_vec_t`, `ecs_ref_t`,
    /// `ecs_map_t`, `ecs_stack_t` and friends — and both of those are set here
    /// explicitly, so both sides agree on them. What `NDEBUG` alone reaches is
    /// `FLECS_NDEBUG`, and `FLECS_NDEBUG` reaches only the log-verbosity macros and
    /// `FLECS_DBG_API`, which changes a symbol's visibility attribute rather than
    /// whether it is declared. `abi_check.zig` asserts the agreement rather than
    /// leaving it to this comment.
    fn applyToModule(self: Macros, module: *std.Build.Module) void {
        for (self.list) |m| module.addCMacro(m.name, m.value orelse "");
    }

    fn applyToTranslateC(self: Macros, tc: *std.Build.Step.TranslateC) void {
        // `std.Build.Step.TranslateC` emits every macro as `-D`, so there is no way to
        // undefine one. The only caller runs in Debug, where Zig defines no NDEBUG in
        // the first place; asserting it here keeps that from silently stopping being
        // true.
        std.debug.assert(!self.undef_ndebug);
        for (self.list) |m| tc.defineCMacro(m.name, m.value);
    }
};

//=============================================================================
// Build
//=============================================================================

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_debug = optimize == .Debug;

    //-------------------------------------------------------------------------
    // Options
    //-------------------------------------------------------------------------

    const shared = b.option(bool, "shared", "Build flecs as a shared library") orelse false;

    const preset = b.option(
        AddonPreset,
        "addons",
        "Starting addon set: full (upstream's default), everything, or minimal",
    ) orelse .full;

    var addons = std.EnumArray(Addon, bool).initUndefined();
    inline for (comptime std.enums.values(Addon)) |addon| {
        const from_preset = presetHas(preset, addon);
        const override = b.option(
            bool,
            addonOption(addon),
            "Enable the " ++ @tagName(addon) ++ " addon (overrides -Daddons)",
        );
        addons.set(addon, override orelse from_preset);
    }

    // flecs.h enables an addon's dependencies for you, but flecs.c has one dependency it
    // does not declare: the alerts addon calls `ecs_script_vars_*` outside any
    // `#ifdef FLECS_SCRIPT`, so alerts without script is nine undefined symbols deep in
    // the amalgamation with nothing pointing at the cause. Turning script back on is a
    // smaller surprise than that link error, and saying so here is what makes it one.
    if (addons.get(.alerts) and !addons.get(.script)) {
        std.log.warn(
            "the alerts addon needs the script addon: flecs.c calls ecs_script_vars_* " ++
                "from alerts without guarding it. Enabling script; pass -Daddon_alerts=false " ++
                "if you meant to drop both.",
            .{},
        );
        addons.set(.script, true);
    }

    const low_footprint = b.option(
        bool,
        "low_footprint",
        "Trade performance for a smaller memory footprint (implies use_os_alloc)",
    ) orelse false;

    // flecs's block allocator is a large part of why it is fast: small objects are
    // served from pools instead of reaching the OS allocator at all. FLECS_USE_OS_ALLOC
    // turns that off, so every allocation is visible to the injected allocator — which
    // is what you want while debugging and not what you want while shipping.
    //
    // Hence the default: on in Debug, off in every release mode. FLECS_LOW_FOOTPRINT
    // defines it unconditionally inside flecs.h, so it is folded in here rather than
    // reported as off while flecs uses it.
    const use_os_alloc = (b.option(
        bool,
        "use_os_alloc",
        "Route every flecs allocation through the OS API (default: Debug only)",
    ) orelse is_debug) or low_footprint;

    const debug_checks_option: DebugChecks = b.option(
        DebugChecks,
        "debug_checks",
        "flecs internal checking: auto (Debug -> sanitize), none, debug, sanitize",
    ) orelse .auto;
    const debug_checks = debug_checks_option.resolve(optimize);

    const sanitize_c = b.option(
        bool,
        "sanitize_c",
        "Zig's C undefined-behaviour sanitizer on flecs (default: Debug only)",
    ) orelse is_debug;

    const track_allocations = b.option(
        bool,
        "track_allocations",
        "Count bytes and blocks handed to flecs (default: Debug only)",
    ) orelse is_debug;

    const keep_assert = b.option(
        bool,
        "keep_assert",
        "Keep flecs asserts even in release builds",
    ) orelse false;

    const soft_assert = b.option(
        bool,
        "soft_assert",
        "Report recoverable errors instead of aborting",
    ) orelse false;

    const debug_info = b.option(
        bool,
        "debug_info",
        "Add debug information to flecs internal data structures (for natvis)",
    ) orelse false;

    const accurate_counters = b.option(
        bool,
        "accurate_counters",
        "Make global statistics counters accurate under threading, at a cost",
    ) orelse false;

    const disable_counters = b.option(
        bool,
        "disable_counters",
        "Disable statistics counters entirely",
    ) orelse false;

    const no_always_inline = b.option(
        bool,
        "no_always_inline",
        "Drop always_inline annotations: smaller binary, slower code",
    ) orelse false;

    const default_to_uncached_queries = b.option(
        bool,
        "default_to_uncached_queries",
        "Make queries uncached unless they need a cache: less memory, slower",
    ) orelse false;

    const float_t = b.option(Precision, "float_t", "Precision of ecs_float_t") orelse .fp32;
    const ftime_t = b.option(Precision, "ftime_t", "Precision of ecs_ftime_t: widen for processes that run for days") orelse .fp32;

    // Sizing constants. Each one is a plain `?usize`: null means "leave flecs's own
    // default alone", which keeps the C side and this build honest about which values
    // were actually chosen here.
    const hi_component_id = b.option(usize, "hi_component_id", "Entity ids below this are reserved for components");
    const hi_id_record_id = b.option(usize, "hi_id_record_id", "Size of the component record lookup array");
    const sparse_page_bits = b.option(usize, "sparse_page_bits", "Page size of sparse sets, as a bit count");
    const entity_page_bits = b.option(usize, "entity_page_bits", "Page size of the entity index, as a bit count");
    const id_desc_max = b.option(usize, "id_desc_max", "Maximum ids in ecs_entity_desc_t / ecs_bulk_desc_t");
    const event_desc_max = b.option(usize, "event_desc_max", "Maximum events in ecs_observer_desc_t");
    const variable_count_max = b.option(usize, "variable_count_max", "Maximum variables per query");
    // flecs names the per-term bitset type ecs_flags<N>_t after this constant, so only
    // the widths that type exists at are usable. Caught here with an explanation rather
    // than as an undeclared-identifier error a thousand lines into the amalgamation.
    const term_count_max = b.option(usize, "term_count_max", "Maximum terms in a query: 8, 16, 32 or 64");
    if (term_count_max) |value| switch (value) {
        8, 16, 32, 64 => {},
        else => std.debug.panic(
            "-Dterm_count_max={d} is not usable: flecs derives its term bitset from this " ++
                "constant as ecs_flags<N>_t, so it must be 8, 16, 32 or 64.",
            .{value},
        ),
    };
    const term_arg_count_max = b.option(usize, "term_arg_count_max", "Maximum arguments for a term");
    const query_variable_count_max = b.option(usize, "query_variable_count_max", "Maximum query variables (must not exceed 128)");
    const query_scope_nesting_max = b.option(usize, "query_scope_nesting_max", "Maximum nesting depth of query scopes");
    const dag_depth_max = b.option(usize, "dag_depth_max", "Maximum depth of an acyclic relationship graph");

    //-------------------------------------------------------------------------
    // Macros
    //-------------------------------------------------------------------------

    var macro_list: std.ArrayList(Macro) = .empty;
    defer macro_list.deinit(b.allocator);

    const define = struct {
        fn f(list: *std.ArrayList(Macro), alloc: std.mem.Allocator, name: []const u8, value: ?[]const u8) void {
            list.append(alloc, .{ .name = name, .value = value }) catch @panic("OOM");
        }
    }.f;

    // Strict C99 sets __STRICT_ANSI__, and glibc then hides everything that is POSIX
    // rather than ISO C. The HTTP addon calls getnameinfo and uses NI_NUMERICHOST, so
    // on glibc it stops compiling unless POSIX is asked for explicitly. This is derived
    // from the addon set rather than hardcoded, so enabling HTTP later brings it along.
    if (target.result.os.tag == .linux and addons.get(.http)) {
        define(&macro_list, b.allocator, "_POSIX_C_SOURCE", "200112L");
    }

    // flecs picks its own checking level from NDEBUG when told nothing, and warns if it
    // is told two things at once — FLECS_DEBUG together with NDEBUG is an "invalid
    // configuration" warning, not a preference. So the level is decided here, once, and
    // NDEBUG follows from it rather than from the optimize mode:
    //
    //   none      -> NDEBUG + FLECS_NDEBUG: no parameter checking, no asserts. The
    //                release default, and the reason release builds pay nothing for
    //                the thousands of asserts in flecs.
    //   debug     -> FLECS_DEBUG: parameter checking and cheap sanity checks.
    //   sanitize  -> FLECS_SANITIZE: the above plus expensive checks. The Debug default.
    //
    // Deciding it here also means the answer does not depend on whether the toolchain
    // happens to define NDEBUG for us.
    switch (debug_checks) {
        .auto => unreachable, // resolved above
        .none => {
            define(&macro_list, b.allocator, "NDEBUG", null);
            define(&macro_list, b.allocator, "FLECS_NDEBUG", null);
        },
        .debug => define(&macro_list, b.allocator, "FLECS_DEBUG", null),
        .sanitize => define(&macro_list, b.allocator, "FLECS_SANITIZE", null),
    }

    // Zig defines NDEBUG for C sources in every release mode. Left alone, asking for
    // checks in a release build would produce exactly the contradiction flecs warns
    // about — FLECS_DEBUG and NDEBUG at once — and a build that says one thing and
    // compiles another. Undefining it makes "ReleaseFast with checks on" a coherent
    // configuration, which is the one worth having when a bug only shows up optimized.
    const undef_ndebug = debug_checks != .none;

    // Brings asserts back on top of a build that would otherwise have none.
    if (keep_assert) define(&macro_list, b.allocator, "FLECS_KEEP_ASSERT", null);

    if (shared) define(&macro_list, b.allocator, "FLECS_SHARED", null);
    if (use_os_alloc) define(&macro_list, b.allocator, "FLECS_USE_OS_ALLOC", null);
    if (low_footprint) define(&macro_list, b.allocator, "FLECS_LOW_FOOTPRINT", null);
    if (soft_assert) define(&macro_list, b.allocator, "FLECS_SOFT_ASSERT", null);
    if (debug_info) define(&macro_list, b.allocator, "FLECS_DEBUG_INFO", null);
    if (accurate_counters) define(&macro_list, b.allocator, "FLECS_ACCURATE_COUNTERS", null);
    if (disable_counters) define(&macro_list, b.allocator, "FLECS_DISABLE_COUNTERS", null);
    if (no_always_inline) define(&macro_list, b.allocator, "FLECS_NO_ALWAYS_INLINE", null);
    if (default_to_uncached_queries) define(&macro_list, b.allocator, "FLECS_DEFAULT_TO_UNCACHED_QUERIES", null);

    define(&macro_list, b.allocator, "ecs_float_t", float_t.ctype());
    define(&macro_list, b.allocator, "ecs_ftime_t", ftime_t.ctype());

    // The addon set is always spelled out, every preset alike: one mechanism, and what
    // the options module reports is exactly what the compiler was told.
    define(&macro_list, b.allocator, "FLECS_CUSTOM_BUILD", null);
    inline for (comptime std.enums.values(Addon)) |addon| {
        if (addons.get(addon)) define(&macro_list, b.allocator, addonDefine(addon), null);
    }

    // FLECS_LOW_FOOTPRINT sets four of these itself, inside flecs.h. Passing them on
    // the command line as well would be a macro redefinition, so low_footprint wins and
    // the values it implies are what the options module reports.
    const sizes = [_]struct { name: []const u8, value: ?usize, forced_by_low_footprint: bool }{
        .{ .name = "FLECS_HI_COMPONENT_ID", .value = hi_component_id, .forced_by_low_footprint = true },
        .{ .name = "FLECS_HI_ID_RECORD_ID", .value = hi_id_record_id, .forced_by_low_footprint = true },
        .{ .name = "FLECS_SPARSE_PAGE_BITS", .value = sparse_page_bits, .forced_by_low_footprint = false },
        .{ .name = "FLECS_ENTITY_PAGE_BITS", .value = entity_page_bits, .forced_by_low_footprint = true },
        .{ .name = "FLECS_ID_DESC_MAX", .value = id_desc_max, .forced_by_low_footprint = false },
        .{ .name = "FLECS_EVENT_DESC_MAX", .value = event_desc_max, .forced_by_low_footprint = false },
        .{ .name = "FLECS_VARIABLE_COUNT_MAX", .value = variable_count_max, .forced_by_low_footprint = false },
        .{ .name = "FLECS_TERM_COUNT_MAX", .value = term_count_max, .forced_by_low_footprint = false },
        .{ .name = "FLECS_TERM_ARG_COUNT_MAX", .value = term_arg_count_max, .forced_by_low_footprint = false },
        .{ .name = "FLECS_QUERY_VARIABLE_COUNT_MAX", .value = query_variable_count_max, .forced_by_low_footprint = false },
        .{ .name = "FLECS_QUERY_SCOPE_NESTING_MAX", .value = query_scope_nesting_max, .forced_by_low_footprint = false },
        .{ .name = "FLECS_DAG_DEPTH_MAX", .value = dag_depth_max, .forced_by_low_footprint = false },
    };
    for (sizes) |size| {
        if (low_footprint and size.forced_by_low_footprint) continue;
        if (size.value) |value| {
            define(&macro_list, b.allocator, size.name, b.fmt("{d}", .{value}));
        }
    }

    const macros = Macros{
        .list = macro_list.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .undef_ndebug = undef_ndebug,
    };
    const c_flags = macros.cFlags(b);

    //-------------------------------------------------------------------------
    // Options module — the Zig side of every choice made above
    //-------------------------------------------------------------------------

    const options_step = b.addOptions();

    // The package's own version, from the manifest rather than from a second literal.
    options_step.addOption([]const u8, "version", manifest.version);

    // Layout-affecting constants. src/c.zig sizes its arrays from these, so a changed
    // constant moves both sides together and the ABI guard proves it landed.
    options_step.addOption(usize, "term_count_max", term_count_max orelse 32);
    options_step.addOption(usize, "event_desc_max", event_desc_max orelse 8);
    options_step.addOption(usize, "id_desc_max", id_desc_max orelse 32);
    options_step.addOption(usize, "term_arg_count_max", term_arg_count_max orelse 16);
    options_step.addOption(bool, "float_is_f64", float_t == .fp64);
    options_step.addOption(bool, "ftime_is_f64", ftime_t == .fp64);

    // Behavioural choices a consumer may reasonably branch on.
    options_step.addOption(bool, "use_os_alloc", use_os_alloc);
    options_step.addOption(bool, "track_allocations", track_allocations);
    options_step.addOption(bool, "low_footprint", low_footprint);
    options_step.addOption(bool, "shared", shared);
    options_step.addOption(DebugChecks, "debug_checks", debug_checks);
    options_step.addOption(bool, "disable_counters", disable_counters);

    // The requested addon set. flecs enables dependencies of its own accord inside the
    // header — asking for pipeline also compiles module, system and timer — so this is
    // what was asked for, not necessarily all of what was built. `ecs_log_set_level(0)`
    // before world creation reports the effective set, and that is the honest source.
    inline for (comptime std.enums.values(Addon)) |addon| {
        options_step.addOption(bool, "addon_" ++ @tagName(addon), addons.get(addon));
    }

    const options_module = options_step.createModule();

    //-------------------------------------------------------------------------
    // The C library
    //-------------------------------------------------------------------------

    const flecs = b.addLibrary(.{
        .name = "flecs",
        .linkage = if (shared) .dynamic else .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    flecs.root_module.addIncludePath(b.path("libs/flecs"));
    flecs.root_module.addCSourceFile(.{
        .file = b.path("libs/flecs/flecs.c"),
        .flags = c_flags,
    });
    flecs.root_module.sanitize_c = if (sanitize_c) .full else .off;

    if (target.result.os.tag == .windows) {
        // Sockets for the HTTP addon, dbghelp for flecs's stack traces.
        flecs.root_module.linkSystemLibrary("ws2_32", .{});
        flecs.root_module.linkSystemLibrary("dbghelp", .{});
    }

    // Installed so a consumer can reach anything this package does not mirror: link the
    // artifact and the real flecs.h is on the include path, ready for @cImport.
    flecs.installHeader(b.path("libs/flecs/flecs.h"), "flecs.h");
    b.installArtifact(flecs);

    //-------------------------------------------------------------------------
    // The Zig module
    //-------------------------------------------------------------------------

    const zecs = b.addModule("zecs", .{
        .root_source_file = b.path("src/zecs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zecs_options", .module = options_module },
        },
    });
    zecs.linkLibrary(flecs);

    //-------------------------------------------------------------------------
    // The ABI manifest
    //
    // The list of every symbol flecs exports, generated from the header rather than
    // written by hand, and the thing `src/abi_check.zig` measures coverage against.
    // Generated at the `everything` preset because that is the only addon set whose
    // header declares them all; the guard skips any entry the current build's header
    // does not declare, which is what makes a reduced addon set a legal configuration
    // rather than a failure.
    //-------------------------------------------------------------------------

    const manifest_translate = b.addTranslateC(.{
        .root_source_file = b.path("libs/flecs/flecs.h"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    manifest_translate.addIncludePath(b.path("libs/flecs"));
    manifestMacros(b).applyToTranslateC(manifest_translate);

    const manifest_tool = b.addExecutable(.{
        .name = "gen-abi-manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_abi_manifest.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const manifest_gen = b.addRunArtifact(manifest_tool);
    manifest_gen.addFileArg(manifest_translate.getOutput());
    const manifest_out = manifest_gen.addOutputFileArg("abi_manifest.zig");

    const manifest_update = b.addUpdateSourceFiles();
    manifest_update.addCopyFileToSource(manifest_out, "src/abi_manifest.zig");
    const manifest_step = b.step(
        "abi-manifest",
        "Regenerate src/abi_manifest.zig from the vendored header",
    );
    manifest_step.dependOn(&manifest_update.step);

    const manifest_check = b.addRunArtifact(manifest_tool);
    manifest_check.addFileArg(manifest_translate.getOutput());
    manifest_check.addArg("--check");
    manifest_check.addFileArg(b.path("src/abi_manifest.zig"));
    manifest_check.expectExitCode(0);
    const manifest_check_step = b.step(
        "abi-manifest-check",
        "Fail if src/abi_manifest.zig is stale with respect to the vendored header",
    );
    manifest_check_step.dependOn(&manifest_check.step);

    // The other generated list: which of the symbols this package binds are flecs's
    // API and which are its insides. The manifest above says what flecs exports; this
    // says what a consumer is entitled to call, and it fails the build if anything
    // above the raw layer has taken a dependency on flecs's implementation.
    const tiers_tool = b.addExecutable(.{
        .name = "gen-api-tiers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_api_tiers.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const tiers_gen = b.addRunArtifact(tiers_tool);
    tiers_gen.addDirectoryArg(b.path("src"));
    const tiers_out = tiers_gen.addOutputFileArg("api_tiers.zig");
    // The tool reads a directory rather than a file list, and a directory's contents
    // are not what the run cache keys on. Both runs are a second, and a check that can
    // be skipped is not a check.
    tiers_gen.has_side_effects = true;

    const tiers_update = b.addUpdateSourceFiles();
    tiers_update.addCopyFileToSource(tiers_out, "src/api_tiers.zig");
    const tiers_step = b.step(
        "api-tiers",
        "Regenerate src/api_tiers.zig from the declarations in src/c/",
    );
    tiers_step.dependOn(&tiers_update.step);

    const tiers_check = b.addRunArtifact(tiers_tool);
    tiers_check.addDirectoryArg(b.path("src"));
    tiers_check.addArg("--check");
    tiers_check.addFileArg(b.path("src/api_tiers.zig"));
    tiers_check.expectExitCode(0);
    tiers_check.has_side_effects = true;
    const tiers_check_step = b.step(
        "api-tiers-check",
        "Fail if src/api_tiers.zig is stale, or if the typed layer calls a flecs internal",
    );
    tiers_check_step.dependOn(&tiers_check.step);

    //-------------------------------------------------------------------------
    // Tests
    //-------------------------------------------------------------------------

    const test_step = b.step("test", "Run the zecs test suite");

    // Compiling the tests without running them. The ABI guard is a compile error by
    // construction, so anything that makes it unhappy is visible here — which is what
    // `ci/mutate.sh` needs, and only that. Running a suite that has already failed to
    // compile is not a stronger check, it is a slower one, and seventeen mutations at a
    // full test run apiece was the slowest thing in CI by an order of magnitude.
    const test_compile_step = b.step(
        "test-compile",
        "Compile the test binaries without running them",
    );

    // The unit tests on their own. They carry the ABI guard and the allocator bridge,
    // and they run in milliseconds because they create no worlds.
    //
    // This is what a configuration that only changes *layout* needs checked. A build
    // option like `-Dterm_count_max=16` moves fields in `ecs_iter_t`; whether that
    // landed on both sides is a compile-time question the guard answers, and re-running
    // the whole behaviour suite afterwards re-proves what the native runs already
    // proved, at a minute a go. Options that change *behaviour* — the allocator mode,
    // the addon set, the footprint — still get the full suite in `ci/run.sh`.
    const test_unit_step = b.step(
        "test-unit",
        "Run only the unit tests: the ABI guard and the allocator bridge",
    );

    // Unit tests: everything with access to the package internals, including the ABI
    // guard and the allocator bridge.
    const unit_tests = b.addTest(.{
        .name = "zecs-unit-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zecs.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zecs_options", .module = options_module },
            },
        }),
    });
    unit_tests.root_module.linkLibrary(flecs);

    // The ABI guard `@cImport`s flecs.h. Both the include path and the macros are wired
    // here, on the test module, and deliberately nowhere else: the shipped module never
    // runs translate-c, and the guard is only worth anything if the header it reads was
    // preprocessed exactly as the library was compiled.
    unit_tests.root_module.addIncludePath(b.path("libs/flecs"));
    macros.applyToModule(unit_tests.root_module);

    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_compile_step.dependOn(&unit_tests.step);

    // Behaviour tests: driven through the public module exactly as a consumer would,
    // with no privileged access. If something here needs an internal, the public
    // surface is wrong.
    //
    // They exercise systems and the pipeline, so they can only be built when those
    // addons are in the set. A build without them is a legitimate configuration — it
    // is what the minimal preset is for — so the suite narrows to the unit tests and
    // says so, rather than failing to link with an undefined symbol.
    const behaviour_tests = b.addTest(.{
        .name = "zecs-behaviour-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/behaviour.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zecs", .module = zecs },
            },
        }),
    });
    if (addons.get(.system) and addons.get(.pipeline)) {
        test_step.dependOn(&b.addRunArtifact(behaviour_tests).step);
        test_compile_step.dependOn(&behaviour_tests.step);
    } else {
        std.log.warn(
            "behaviour tests skipped: they need the system and pipeline addons, " ++
                "which this addon set does not include. The ABI and allocator tests still run.",
            .{},
        );
    }

    //-------------------------------------------------------------------------
    // Documentation
    //
    // Zig's own generated reference for the typed layer and the raw declarations, which
    // means the doc comments in `src/` are the documentation rather than a second copy
    // of it that can go stale.
    //-------------------------------------------------------------------------

    const docs_obj = b.addObject(.{
        .name = "zecs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zecs.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zecs_options", .module = options_module },
            },
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    //-------------------------------------------------------------------------
    // Benchmarks
    //-------------------------------------------------------------------------

    // The benchmark's own knob, kept out of the library's options: which allocator
    // flecs is given. It changes what is being measured, not how zecs is built.
    const bench_options = b.addOptions();
    bench_options.addOption(bool, "locking_allocator", b.option(
        bool,
        "bench_locking_allocator",
        "Benchmark against a mutex-guarded checking allocator instead of a fast one",
    ) orelse false);

    const bench = b.addExecutable(.{
        .name = "zecs-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            // Deliberately the optimize mode that was asked for, not a better one. The
            // whole library — flecs included — is built one way per invocation, so
            // silently upgrading this half would produce numbers for a configuration
            // that does not exist. The benchmark says so at runtime when it is being
            // run against a Debug build.
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zecs", .module = zecs },
                .{ .name = "bench_options", .module = bench_options.createModule() },
            },
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run the zecs benchmarks");
    bench_step.dependOn(&bench_run.step);

    // Compiling the benchmark without running it, because running it takes minutes and
    // compiling it is what CI actually needs. The benchmark is the package's only
    // consumer of the public API that is not a test, and nothing compiled it: a rename
    // in `QueryDesc` left it broken through several commits, found by hand rather than
    // by a gate. A source in the repository that no step compiles is a source that
    // rots.
    const bench_compile_step = b.step("bench-compile", "Compile the benchmarks without running them");
    bench_compile_step.dependOn(&bench.step);
}

/// The canonical preprocessor state for the ABI manifest: every addon on, checks on,
/// and no sizing constant touched. It is deliberately independent of the options the
/// build was invoked with, because the manifest describes what flecs exports, not what
/// one configuration happens to compile.
fn manifestMacros(b: *std.Build) Macros {
    var list: std.ArrayList(Macro) = .empty;
    list.append(b.allocator, .{ .name = "FLECS_CUSTOM_BUILD" }) catch @panic("OOM");
    inline for (comptime std.enums.values(Addon)) |addon| {
        list.append(b.allocator, .{ .name = addonDefine(addon) }) catch @panic("OOM");
    }
    // Symbol *visibility* varies with FLECS_NDEBUG (flecs marks a handful of internals
    // FLECS_DBG_API), but the set of declarations does not. Checks are switched on so
    // the generated list is the widest one, and so a reader is not left wondering.
    list.append(b.allocator, .{ .name = "FLECS_DEBUG" }) catch @panic("OOM");
    return .{
        .list = list.toOwnedSlice(b.allocator) catch @panic("OOM"),
        // The translate-c step is built in Debug, so Zig defines no NDEBUG to undo.
        .undef_ndebug = false,
    };
}
