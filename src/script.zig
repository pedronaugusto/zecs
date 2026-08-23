//! The flecs script addon: a small language for scenes, assets and configuration, and
//! the expression evaluator underneath it.
//!
//! ```
//! sun {
//!   Position: {x: 0, y: 0}
//!   Light: {intensity: 4}
//!
//!   earth {
//!     Position: {x: 10, y: 0}
//!   }
//! }
//! ```
//!
//! A script names components by the name they were registered under and fills them in
//! by member name, so a component it can set has to be described to flecs's reflection
//! layer as well as registered — a plain `World.component` gives flecs a size, not a
//! shape.
//!
//! ## What this file is for
//!
//! Almost every function in the addon takes a C string and reports failure by returning
//! null or a non-zero int, so almost every function in it earns a wrapper: a Zig slice
//! going in, an error coming out, and a `deinit` on the two things that are resources.
//! The rest of the addon — the strbuf variants, functions and methods, the AST visitors
//! — is reachable raw through `zecs.c`.
//!
//! ## Where the error message goes
//!
//! flecs writes parse and evaluation failures to its log, which is stderr by default.
//! Passing a `Diagnostic` captures the message instead and keeps the log quiet, which
//! is what a host wants when a failed script is a normal outcome rather than a bug.
//!
//! ## Addon
//!
//! Gated on `zecs.options.addon_script`, which the default and `everything` presets
//! include and `minimal` does not. Calling into this file from a build without the
//! addon is a compile error naming the option.

const std = @import("std");
const c = @import("c.zig");
const options = @import("zecs_options");
const types = @import("types.zig");
const component_mod = @import("component.zig");
const value_mod = @import("value.zig");
const world_mod = @import("world.zig");
const Error = @import("error.zig").Error;

const Entity = types.Entity;
const Id = types.Id;
const World = world_mod.World;
const Component = component_mod.Component;

/// Guards every entry point in this file. The condition is comptime, so a build with
/// the addon pays nothing and a build without it fails where the call is written rather
/// than at link time with an undefined symbol.
inline fn requireAddon() void {
    if (!options.addon_script) @compileError(
        "zecs: this build has no flecs script addon. Enable it with -Daddon_script, " ++
            "or branch on zecs.options.addon_script in code that has to work either way.",
    );
}

//=============================================================================
// Diagnostics
//=============================================================================

/// What flecs said about a script that did not parse or did not run.
///
/// Declare one next to the call and `defer` its `deinit`: the message is heap memory
/// flecs allocated, and a successful call can leave one too — a script that logged an
/// error and recovered still fills this in.
pub const Diagnostic = struct {
    /// flecs's message, owned by this struct. Null when flecs had nothing to say,
    /// which is the normal case for a success and also happens for a failure in a build
    /// without the log addon, where flecs has nowhere to capture from.
    message: ?[:0]u8 = null,
    /// Where the parser stopped. Zero when flecs could not place the failure.
    line: i32 = 0,
    column: i32 = 0,

    /// Releases the message. Safe on an empty diagnostic and safe twice.
    pub fn deinit(self: *Diagnostic) void {
        if (self.message) |m| value_mod.freeString(m);
        self.* = .{};
    }

    fn take(self: *Diagnostic, result: c.ecs_script_eval_result_t) void {
        self.deinit();
        self.* = .{
            .message = if (result.@"error") |e| std.mem.span(e) else null,
            .line = result.line,
            .column = result.column,
        };
    }
};

/// Options for parsing a script.
pub const ParseDesc = struct {
    /// The name the parser puts in its messages. Any short label will do; a file path
    /// is the usual choice.
    name: [:0]const u8 = "script",
    diagnostic: ?*Diagnostic = null,
};

/// Options for evaluating a parsed script.
pub const EvalDesc = struct {
    /// Variables the script can read. See `Vars`.
    vars: ?Vars = null,
    /// A runtime to reuse across evaluations, from `zecs.c.ecs_script_runtime_new`.
    /// With none, flecs makes one for the call and throws it away afterwards.
    runtime: ?*c.ecs_script_runtime_t = null,
    diagnostic: ?*Diagnostic = null,
};

/// Options for running a script in one go.
pub const RunDesc = struct {
    name: [:0]const u8 = "script",
    diagnostic: ?*Diagnostic = null,
};

/// Options for loading a managed script. Exactly one of `filename` and `code`.
pub const LoadDesc = struct {
    /// Reuse an entity for the script rather than letting flecs make one.
    entity: Entity = 0,
    filename: ?[:0]const u8 = null,
    code: ?[:0]const u8 = null,
};

//=============================================================================
// Scripts
//=============================================================================

/// A parsed script, kept so it can be evaluated more than once.
///
/// Parsing is the expensive half — it allocates an AST and a token buffer that live as
/// long as this object — and evaluating is what changes the world. `run` is the one-shot
/// form for a script evaluated exactly once, which is most of them.
pub const Script = struct {
    raw: *c.ecs_script_t,

    //=========================================================================
    // One-shot
    //=========================================================================

    /// Parses and evaluates a script against the world, creating the entities and
    /// setting the components it describes.
    ///
    /// The scope is reset to the root for the duration, so a script always builds from
    /// the same place regardless of what `ecs_set_scope` was left at. flecs restores it
    /// on the way out only when the script succeeded: a script that fails to evaluate
    /// leaves the scope at the root, so a caller that uses scopes should set the one it
    /// wants again after an error rather than assume it survived.
    ///
    /// flecs does not say which half failed, so both come back as the same error; the
    /// diagnostic's message does distinguish them.
    pub fn run(world: World, code: [:0]const u8, desc: RunDesc) Error!void {
        requireAddon();
        var result: c.ecs_script_eval_result_t = .{};
        const rc = c.ecs_script_run(
            world.raw,
            desc.name.ptr,
            code.ptr,
            if (desc.diagnostic != null) &result else null,
        );
        if (desc.diagnostic) |d| d.take(result);
        if (rc != 0) return Error.ScriptRunFailed;
    }

    /// `run` for a script on disk. flecs reads the file through its OS API and uses the
    /// path as the parser's name.
    ///
    /// A file that cannot be read fails the same way a script that cannot be parsed
    /// does, and flecs offers no result parameter here, so a diagnostic is not
    /// available for this one.
    pub fn runFile(world: World, path: [:0]const u8) Error!void {
        requireAddon();
        if (c.ecs_script_run_file(world.raw, path.ptr) != 0) return Error.ScriptRunFailed;
    }

    //=========================================================================
    // Parse and evaluate separately
    //=========================================================================

    /// Parses a script without running it. Release it with `deinit`.
    pub fn parse(world: World, code: [:0]const u8, desc: ParseDesc) Error!Script {
        requireAddon();
        var result: c.ecs_script_eval_result_t = .{};
        const eval_desc: c.ecs_script_eval_desc_t = .{};
        const raw = c.ecs_script_parse(
            world.raw,
            desc.name.ptr,
            code.ptr,
            &eval_desc,
            if (desc.diagnostic != null) &result else null,
        );
        if (desc.diagnostic) |d| d.take(result);
        return .{ .raw = raw orelse return Error.ScriptParseFailed };
    }

    pub fn deinit(self: Script) void {
        c.ecs_script_free(self.raw);
    }

    /// Evaluates a parsed script against the world it was parsed for. May be called
    /// more than once, with different variables each time.
    pub fn eval(self: Script, desc: EvalDesc) Error!void {
        requireAddon();
        var result: c.ecs_script_eval_result_t = .{};
        const eval_desc: c.ecs_script_eval_desc_t = .{
            .vars = if (desc.vars) |v| v.raw else null,
            .runtime = desc.runtime,
        };
        const rc = c.ecs_script_eval(
            self.raw,
            &eval_desc,
            if (desc.diagnostic != null) &result else null,
        );
        if (desc.diagnostic) |d| d.take(result);
        if (rc != 0) return Error.ScriptEvalFailed;
    }

    /// The parsed syntax tree, printed. For looking at what the parser made of a
    /// script; `colors` adds terminal escapes.
    ///
    /// The caller owns the string and frees it with `zecs.freeString`. The strbuf form,
    /// `zecs.c.ecs_script_ast_to_buf`, is raw: it writes into flecs's string builder,
    /// which has its own adapter.
    pub fn astToString(self: Script, colors: bool) ?[:0]u8 {
        requireAddon();
        return std.mem.span(c.ecs_script_ast_to_str(self.raw, colors) orelse return null);
    }

    //=========================================================================
    // Managed scripts
    //=========================================================================

    /// Loads a script as an entity that remembers what it created — `ecs_script_init`.
    ///
    /// The difference from `run` is what happens next: `update` re-runs the script and
    /// deletes the entities the new version no longer mentions, which is what makes a
    /// script file reloadable while a program is running.
    pub fn load(world: World, desc: LoadDesc) Error!Entity {
        requireAddon();
        const c_desc: c.ecs_script_desc_t = .{
            .entity = desc.entity,
            .filename = if (desc.filename) |f| f.ptr else null,
            .code = if (desc.code) |code| code.ptr else null,
        };
        const e = c.ecs_script_init(world.raw, &c_desc);
        if (e == 0) return Error.ScriptInitFailed;
        return e;
    }

    /// Replaces a managed script's code and reconciles the world with it. `instance` is
    /// the entity the script was instantiated on, or 0 for the script itself.
    pub fn update(world: World, script: Entity, instance: Entity, code: [:0]const u8) Error!void {
        requireAddon();
        if (c.ecs_script_update(world.raw, script, instance, code.ptr) != 0) {
            return Error.ScriptRunFailed;
        }
    }
};

//=============================================================================
// Variables
//=============================================================================

/// A scope of variables a script or an expression can read.
///
/// Values are stored by type, the same way components are, so setting one needs the
/// component handle as well as the value. Nested scopes exist in flecs
/// (`ecs_script_vars_push` and `pop`, raw) and shadow rather than replace.
pub const Vars = struct {
    raw: *c.ecs_script_vars_t,

    /// Creates a root scope. Release it with `deinit`.
    pub fn init(world: World) Error!Vars {
        requireAddon();
        return .{ .raw = c.ecs_script_vars_init(world.raw) orelse return Error.VariableScopeInitFailed };
    }

    pub fn deinit(self: Vars) void {
        c.ecs_script_vars_fini(self.raw);
    }

    /// Declares a variable holding `comp`'s type and gives it a value.
    ///
    /// **flecs keeps the name pointer rather than copying the string.** The name has to
    /// outlive the scope, so a string literal or something owned elsewhere — not a
    /// stack buffer that goes out of scope first.
    ///
    /// Fails when the name is already declared in this scope, and when the component's
    /// entity is not a type flecs has reflection for.
    pub inline fn set(
        self: Vars,
        name: [:0]const u8,
        comp: anytype,
        value: @TypeOf(comp).Type,
    ) Error!void {
        requireAddon();
        comptime std.debug.assert(@sizeOf(@TypeOf(comp).Type) != 0);
        const declared = c.ecs_script_vars_define_id(self.raw, name.ptr, comp.asId()) orelse
            return Error.VariableDeclareFailed;
        const ptr = declared.value.ptr orelse return Error.VariableDeclareFailed;
        const typed: *@TypeOf(comp).Type = @ptrCast(@alignCast(ptr));
        typed.* = value;
    }

    /// A variable's storage, for reading it or writing it in place.
    ///
    /// Null when there is no such variable in this scope or any parent of it, and null
    /// when there is one but it holds a different type — a variable's type is fixed
    /// when it is declared, and reading it as something else is the mistake this
    /// catches.
    pub inline fn get(self: Vars, name: [:0]const u8, comp: anytype) ?*@TypeOf(comp).Type {
        requireAddon();
        const found = c.ecs_script_vars_lookup(self.raw, name.ptr) orelse return null;
        if (found.value.type != comp.asId()) return null;
        const ptr = found.value.ptr orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Substitutes `$name` and `{expression}` in a string with what these variables say
    /// they are, and returns the result.
    ///
    /// The caller owns the string and frees it with `zecs.freeString`. Null when an
    /// expression in the string did not evaluate.
    pub fn interpolate(self: Vars, world: World, text: [:0]const u8) ?[:0]u8 {
        requireAddon();
        return std.mem.span(
            c.ecs_script_string_interpolate(world.raw, text.ptr, self.raw) orelse return null,
        );
    }
};

//=============================================================================
// Expressions
//=============================================================================

/// An expression parsed once and evaluated many times.
///
/// The result type is fixed when the expression is parsed: flecs type-checks and folds
/// against it, so `Expr(f64).parse(world, "1 + 2", ...)` produces `3.0` and the same
/// text parsed against an integer produces `3`. Release it with `deinit`.
///
/// For an expression evaluated once, `evalExpr` does the whole thing in a call.
pub fn Expr(comptime T: type) type {
    return struct {
        const Self = @This();

        raw: *c.ecs_script_t,
        type_id: Id,

        /// Parses `text` as an expression producing `comp`'s type.
        pub fn parse(world: World, text: [:0]const u8, comp: Component(T)) Error!Self {
            requireAddon();
            const desc: c.ecs_expr_eval_desc_t = .{ .type = comp.asId() };
            const raw = c.ecs_expr_parse(world.raw, text.ptr, &desc) orelse
                return Error.ExpressionFailed;
            return .{ .raw = raw, .type_id = comp.asId() };
        }

        pub fn deinit(self: Self) void {
            c.ecs_script_free(self.raw);
        }

        /// Evaluates the expression and returns the result.
        pub inline fn eval(self: Self) Error!T {
            requireAddon();
            var out: T = undefined;
            var value: c.ecs_value_t = .{ .type = self.type_id, .ptr = &out };
            const desc: c.ecs_expr_eval_desc_t = .{ .type = self.type_id };
            if (c.ecs_expr_eval(self.raw, &value, &desc) != 0) return Error.ExpressionFailed;
            return out;
        }
    };
}

/// Parses and evaluates an expression, and returns the result as `comp`'s type.
///
/// This is the whole point of the reflection layer from Zig's side: flecs's `void*` and
/// type entity become a value of a type the compiler knows. `Expr` is the form to reach
/// for when the same text is evaluated more than once.
pub inline fn evalExpr(world: World, text: [:0]const u8, comp: anytype) Error!@TypeOf(comp).Type {
    requireAddon();
    var out: @TypeOf(comp).Type = undefined;
    var value: c.ecs_value_t = .{ .type = comp.asId(), .ptr = &out };
    const desc: c.ecs_expr_eval_desc_t = .{ .type = comp.asId() };
    // The return is a pointer into the text just past what was consumed; null is the
    // failure signal, and there is nothing else useful in it for a whole expression.
    if (c.ecs_expr_run(world.raw, text.ptr, &value, &desc) == null) return Error.ExpressionFailed;
    return out;
}
