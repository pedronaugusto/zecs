//! flecs C declarations for the script addon.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const core = @import("core.zig");

// Re-exported so a caller of this module sees one namespace rather than
// having to know which area a shared declaration came from.
pub const ecs_ctx_free_t = core.ecs_ctx_free_t;
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_iter_t = core.ecs_iter_t;
pub const ecs_strbuf_t = core.ecs_strbuf_t;
pub const ecs_type_info_t = core.ecs_type_info_t;
pub const ecs_value_t = core.ecs_value_t;
pub const ecs_vec_t = core.ecs_vec_t;
pub const ecs_world_t = core.ecs_world_t;

/// Import the script math module, the equivalent of `ECS_IMPORT(world, FlecsScriptMath)`
/// in C. Registers the math functions scripts can call.
pub extern fn FlecsScriptMathImport(world: *ecs_world_t) void;

pub extern var EcsScriptTemplate: ecs_entity_t;

pub extern var EcsScriptVectorType: ecs_entity_t;

pub const ecs_script_template_t = opaque {};

/// A script variable. `sp` is its stack pointer, for `ecs_script_vars_from_sp`.
pub const ecs_script_var_t = extern struct {
    /// Null for an anonymous variable.
    name: ?[*:0]const u8 = null,
    value: ecs_value_t = .{},
    type_info: ?*const ecs_type_info_t = null,
    sp: i32 = 0,
    is_const: bool = false,
};

/// A scope of script variables. flecs defines this type, but it holds an
/// `ecs_hashmap_t`, which this file keeps opaque.
pub const ecs_script_vars_t = opaque {};

pub const ecs_script_t = extern struct {
    world: ?*ecs_world_t = null,
    name: ?[*:0]const u8 = null,
    code: ?[*:0]const u8 = null,
};

/// Runtime for executing scripts.
pub const ecs_script_runtime_t = opaque {};

/// Added to the entity of a managed script or a template. Everything in it is owned by
/// flecs.
pub const EcsScript = extern struct {
    filename: ?[*:0]u8 = null,
    code: ?[*:0]u8 = null,
    /// Set when evaluating the script produced errors.
    @"error": ?[*:0]u8 = null,
    script: ?*ecs_script_t = null,
    /// Only set for a template script.
    template_: ?*ecs_script_template_t = null,
};

pub const ecs_function_ctx_t = extern struct {
    world: ?*ecs_world_t = null,
    function: ecs_entity_t = 0,
    ctx: ?*anyopaque = null,
};

/// A function a script can call. `argv` points at `argc` values, and the callback writes
/// through `result`, whose type is the function's declared return type.
pub const ecs_function_callback_t = ?*const fn (ctx: ?*const ecs_function_ctx_t, argc: i32, argv: ?[*]const ecs_value_t, result: ?*ecs_value_t) callconv(.c) void;

/// Same as `ecs_function_callback_t`, over `elem_count` elements at once.
pub const ecs_vector_function_callback_t = ?*const fn (ctx: ?*const ecs_function_ctx_t, argc: i32, argv: ?[*]const ecs_value_t, result: ?*ecs_value_t, elem_count: i32) callconv(.c) void;

/// One parameter of a script function.
pub const ecs_script_parameter_t = extern struct {
    name: ?[*:0]const u8 = null,
    type: ecs_entity_t = 0,
};

/// A const variable scripts can read, on the entity `ecs_const_var_init` created. The
/// value is owned by flecs.
pub const EcsScriptConstVar = extern struct {
    value: ecs_value_t = .{},
    type_info: ?*const ecs_type_info_t = null,
};

pub const ecs_script_function_t = extern struct {
    return_type: ecs_entity_t = 0,
    /// `ecs_vec_t` of `ecs_script_parameter_t`.
    params: ecs_vec_t = .{},
    callback: ecs_function_callback_t = null,
    vector_callbacks: [18]ecs_vector_function_callback_t = @splat(null),
    ctx: ?*anyopaque = null,
    binding_ctx: ?*anyopaque = null,
    binding_ctx_free: ecs_ctx_free_t = null,
};

pub const ecs_script_eval_desc_t = extern struct {
    /// Variables the script refers to.
    vars: ?*ecs_script_vars_t = null,
    /// Reusable runtime. Null makes one for the duration of the call.
    runtime: ?*ecs_script_runtime_t = null,
};

/// Captured error output from parsing or evaluating a script.
pub const ecs_script_eval_result_t = extern struct {
    /// Null when there was no error. Otherwise heap memory the caller frees with
    /// `ecs_os_free`.
    @"error": ?[*:0]u8 = null,
    /// 1-based line of the first error, 0 when not known.
    line: i32 = 0,
    /// 1-based column of the first error, 0 when not known.
    column: i32 = 0,
};

/// Parse a script into a script object, to be run with `ecs_script_eval`. Null on a
/// parse error. A script that reads outside variables needs a `desc.vars` scope
/// declaring all of them with the right types. Passing `result` turns on error capture;
/// `result.error` is then heap memory the caller frees. Both `desc` and `result` may be
/// null. `name` is used in error messages. `code` null is read as an empty script.
pub extern fn ecs_script_parse(world: *ecs_world_t, name: ?[*:0]const u8, code: ?[*:0]const u8, desc: ?*const ecs_script_eval_desc_t, result: ?*ecs_script_eval_result_t) ?*ecs_script_t;

/// Run a parsed script. The variable scope may differ from the one `ecs_script_parse`
/// saw, as long as it declares the same variables with the same types. Passing `result`
/// turns on error capture; `result.error` is then heap memory the caller frees. Both
/// `desc` and `result` may be null.
pub extern fn ecs_script_eval(script: *const ecs_script_t, desc: ?*const ecs_script_eval_desc_t, result: ?*ecs_script_eval_result_t) c_int;

/// Release a script object. Templates the script created hold a reference to it, so the
/// object outlives this call until the last of them is deleted.
pub extern fn ecs_script_free(script: *ecs_script_t) void;

/// Parse a script and instantiate its entities in one call: `ecs_script_parse`, then
/// `ecs_script_eval`, then `ecs_script_free`. `result` is optional and works as it does
/// for `ecs_script_parse`.
pub extern fn ecs_script_run(world: *ecs_world_t, name: ?[*:0]const u8, code: ?[*:0]const u8, result: ?*ecs_script_eval_result_t) c_int;

/// Same as `ecs_script_run`, reading the script from a file. The filename doubles as the
/// script name in error messages.
pub extern fn ecs_script_run_file(world: *ecs_world_t, filename: [*:0]const u8) c_int;

/// Create a script runtime, the container for whatever evaluating a script allocates.
/// `ecs_script_run` and `ecs_script_eval` make one per call when not given one, so this
/// is a way to amortize that across many evaluations. Each thread needs its own. Release
/// it with `ecs_script_runtime_free`.
pub extern fn ecs_script_runtime_new() ?*ecs_script_runtime_t;

pub extern fn ecs_script_runtime_free(runtime: *ecs_script_runtime_t) void;

/// Render a script's abstract syntax tree into a buffer, for debugging a script.
pub extern fn ecs_script_ast_to_buf(script: *ecs_script_t, buf: *ecs_strbuf_t, colors: bool) c_int;

/// Same as `ecs_script_ast_to_buf`, returning a string. Null on failure or when the
/// script has no AST. Free the result with `ecs_os_free`.
pub extern fn ecs_script_ast_to_str(script: *ecs_script_t, colors: bool) ?[*:0]u8;

pub const ecs_script_desc_t = extern struct {
    entity: ecs_entity_t = 0,
    filename: ?[*:0]const u8 = null,
    code: ?[*:0]const u8 = null,
};

/// Load a managed script: one that remembers the entities it created and keeps them in
/// step when its code is replaced, deleting the ones the new version no longer defines.
/// Experimental, in flecs's own words.
pub extern fn ecs_script_init(world: *ecs_world_t, desc: *const ecs_script_desc_t) ecs_entity_t;

/// Replace a managed script's code, reconciling the entities it created. `instance` is
/// optional and names a template instance.
pub extern fn ecs_script_update(world: *ecs_world_t, script: ecs_entity_t, instance: ecs_entity_t, code: ?[*:0]const u8) c_int;

/// Delete every entity a managed script created.
pub extern fn ecs_script_clear(world: *ecs_world_t, script: ecs_entity_t, instance: ecs_entity_t) void;

/// Create a root variable scope. Scopes nest, so the same name can mean different things
/// at different depths, with the innermost winning. A variable holding an allocated
/// value is destructed by `ecs_script_vars_pop` when it has type info with a `dtor`
/// hook. Release the root with `ecs_script_vars_fini`.
pub extern fn ecs_script_vars_init(world: *ecs_world_t) ?*ecs_script_vars_t;

/// Release a root variable scope, which must have no parent. Pops the scope on the way.
pub extern fn ecs_script_vars_fini(vars: *ecs_script_vars_t) void;

/// Push a nested variable scope, inheriting the parent's stack and allocator. Null
/// parent makes a root scope. Pair it with `ecs_script_vars_pop`.
pub extern fn ecs_script_vars_push(parent: ?*ecs_script_vars_t) ?*ecs_script_vars_t;

/// Pop a variable scope, releasing its variables, and return its parent. The scope must
/// be the top of the stack; popping any other is undefined behaviour.
pub extern fn ecs_script_vars_pop(vars: *ecs_script_vars_t) ?*ecs_script_vars_t;

/// Declare a variable in the current scope without allocating storage for it, so that it
/// can point at a value that already exists. Null `name` declares an anonymous variable,
/// reachable only by stack pointer. Null when the scope already has that name.
pub extern fn ecs_script_vars_declare(vars: *ecs_script_vars_t, name: ?[*:0]const u8) ?*ecs_script_var_t;

/// Declare a variable and allocate storage for it from the scope's stack allocator,
/// running the type's ctor. The storage dies with the scope. Null when `type` is not a
/// type or the name is taken.
pub extern fn ecs_script_vars_define_id(vars: *ecs_script_vars_t, name: ?[*:0]const u8, @"type": ecs_entity_t) ?*ecs_script_var_t;

/// Look a variable up by name, walking out to the parent scopes when the current one
/// does not have it. Null when no scope does, and when `vars` itself is null.
pub extern fn ecs_script_vars_lookup(vars: ?*const ecs_script_vars_t, name: [*:0]const u8) ?*ecs_script_var_t;

/// Look a variable up by stack pointer, faster than by name, for scopes whose variables
/// are always declared in the same order. Null when `sp` is out of range.
pub extern fn ecs_script_vars_from_sp(vars: *const ecs_script_vars_t, sp: i32) ?*ecs_script_var_t;

/// Print the variables of a scope and its parents to stdout.
pub extern fn ecs_script_vars_print(vars: *const ecs_script_vars_t) void;

/// Reserve room for `count` variables. A performance tweak only, and the scope must
/// still be empty.
pub extern fn ecs_script_vars_set_size(vars: *ecs_script_vars_t, count: i32) void;

/// Bind an iterator's current result to variables, so that expressions can read it. Does
/// not advance the iterator. Fields become variables named by index — `$1`, `$2` — and
/// query variables that hold a single entity become variables under their own names.
/// `offset` picks which element of the component arrays to bind, and must be below
/// `it.count`. The variables point into the iterator's data, so they die with it or when
/// it advances. An existing variable whose type does not match makes this fail; a
/// variable the iterator says nothing about is left alone. No reflection data is
/// required here, but using such a variable in an expression will fail.
pub extern fn ecs_script_vars_from_iter(it: *const ecs_iter_t, vars: *ecs_script_vars_t, offset: c_int) void;

pub const ecs_expr_eval_desc_t = extern struct {
    /// Script name, used in log messages only.
    name: ?[*:0]const u8 = null,
    /// The full expression, used in log messages only.
    expr: ?[*:0]const u8 = null,
    /// Variables the expression may read.
    vars: ?*const ecs_script_vars_t = null,
    /// Expected type of the result.
    type: ecs_entity_t = 0,
    /// Replaces the default identifier lookup, which is `ecs_lookup`.
    lookup_action: ?*const fn (world: ?*const ecs_world_t, value: ?[*:0]const u8, ctx: ?*anyopaque) callconv(.c) ecs_entity_t = null,
    lookup_ctx: ?*anyopaque = null,
    /// Skip constant folding: parses faster, evaluates slower.
    disable_folding: bool = false,
    /// Bind variables by stack pointer rather than by name, which is faster but requires
    /// that they are always declared in the same order.
    disable_dynamic_variable_binding: bool = false,
    /// Tolerate identifiers that do not resolve yet, for entities created between
    /// parsing and evaluation.
    allow_unresolved_identifiers: bool = false,
    /// Reusable runtime. Null makes one for the duration of the call.
    runtime: ?*ecs_script_runtime_t = null,
    /// flecs-internal.
    script_visitor: ?*anyopaque = null,
    /// flecs-internal.
    unresolved_identifier_action: ?*const fn (world: ?*const ecs_world_t, value: ?[*:0]const u8, ctx: ?*anyopaque) callconv(.c) bool = null,
};

/// Parse and evaluate an expression in one call, writing through `value`. The result is
/// cast when `value.type` differs from the expression's type. A `value.ptr` of null asks
/// flecs to allocate the storage, which the caller then releases with `ecs_value_free`.
/// Returns a pointer into `ptr` just past the last character read, or null on failure.
/// `desc` may be null.
pub extern fn ecs_expr_run(world: *ecs_world_t, ptr: [*:0]const u8, value: *ecs_value_t, desc: ?*const ecs_expr_eval_desc_t) ?[*:0]const u8;

/// Parse an expression into an object that `ecs_expr_eval` can run repeatedly. Null on a
/// parse error. `desc` may be null. Release it with `ecs_script_free`.
pub extern fn ecs_expr_parse(world: *ecs_world_t, expr: [*:0]const u8, desc: ?*const ecs_expr_eval_desc_t) ?*ecs_script_t;

/// Evaluate an expression parsed by `ecs_expr_parse`, writing through `value` as
/// `ecs_expr_run` does. `desc` may be null.
pub extern fn ecs_expr_eval(script: *const ecs_script_t, value: *ecs_value_t, desc: ?*const ecs_expr_eval_desc_t) c_int;

/// Replace the expressions embedded in a string with their values. The two forms are
/// `$variable_name` and `{expression}`, and `$`, `{` and `}` are escaped with a
/// backslash. Null on failure. Free the result with `ecs_os_free`.
pub extern fn ecs_script_string_interpolate(world: *ecs_world_t, str: [*:0]const u8, vars: ?*const ecs_script_vars_t) ?[*:0]u8;

pub const ecs_const_var_desc_t = extern struct {
    name: ?[*:0]const u8 = null,
    /// Namespace to create the variable under.
    parent: ecs_entity_t = 0,
    type: ecs_entity_t = 0,
    /// Copied into flecs's own storage, so it need not outlive the call.
    value: ?*anyopaque = null,
};

/// Create a const variable scripts can read. `desc.name`, `desc.type` and `desc.value`
/// are all required; 0 when the name is already taken under that parent.
pub extern fn ecs_const_var_init(world: *ecs_world_t, desc: *ecs_const_var_desc_t) ecs_entity_t;

/// The value of a const variable, from `ecs_const_var_init` or from `export const v: ...`
/// in a script. Owned by the variable's entity.
pub extern fn ecs_const_var_get(world: *const ecs_world_t, @"var": ecs_entity_t) ecs_value_t;

pub const ecs_vector_fn_callbacks_t = extern struct {
    i8: ecs_vector_function_callback_t = null,
    i32: ecs_vector_function_callback_t = null,
};

pub const ecs_function_desc_t = extern struct {
    name: ?[*:0]const u8 = null,
    /// Namespace to create the function under. For a method this is the type it is
    /// called on.
    parent: ecs_entity_t = 0,
    /// Zero-terminated: the first entry with a null name ends the list.
    params: [16]ecs_script_parameter_t = @splat(.{}),
    return_type: ecs_entity_t = 0,
    callback: ecs_function_callback_t = null,
    /// Needed when a parameter has type `EcsScriptVectorType`, which lets one function
    /// be called with any struct whose members share a primitive type. Indexed by
    /// `ecs_primitive_kind_t`.
    vector_callbacks: [18]ecs_vector_function_callback_t = @splat(null),
    ctx: ?*anyopaque = null,
};

/// Create a function a script can call.
pub extern fn ecs_function_init(world: *ecs_world_t, desc: *const ecs_function_desc_t) ecs_entity_t;

/// Create a method a script can call on an instance of a type. Like a function, except
/// that it lives in the scope of `desc.parent`, which is the type, and receives the
/// instance as its first argument.
pub extern fn ecs_method_init(world: *ecs_world_t, desc: *const ecs_function_desc_t) ecs_entity_t;

/// Serialize a value to a script expression, which parses back to the same value. Null
/// when the type has no reflection data. Free the result with `ecs_os_free`.
pub extern fn ecs_ptr_to_expr(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque) ?[*:0]u8;

/// Same as `ecs_ptr_to_expr`, appending to an `ecs_strbuf_t` instead.
pub extern fn ecs_ptr_to_expr_buf(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque, buf: *ecs_strbuf_t) c_int;

/// Serialize a value for reading rather than for parsing: the same as `ecs_ptr_to_expr`
/// except that strings come out unquoted. Free the result with `ecs_os_free`.
pub extern fn ecs_ptr_to_str(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque) ?[*:0]u8;

/// Same as `ecs_ptr_to_str`, appending to an `ecs_strbuf_t` instead.
pub extern fn ecs_ptr_to_str_buf(world: *const ecs_world_t, @"type": ecs_entity_t, data: *const anyopaque, buf: *ecs_strbuf_t) c_int;

pub const ecs_expr_node_t = opaque {};

/// Import the script module, the equivalent of `ECS_IMPORT(world, FlecsScript)` in C.
pub extern fn FlecsScriptImport(world: *ecs_world_t) void;
