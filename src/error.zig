//! The errors zecs reports.
//!
//! flecs's own failure style is to log and abort, or to return a zero id and carry on.
//! Neither is much use to a caller, so the wrapper turns the failures it can observe
//! into errors. Where flecs aborts before returning — a failed allocation, a failed
//! internal assertion — there is nothing to translate, and the README says so rather
//! than implying a recovery path that does not exist.

pub const Error = error{
    /// An allocator was offered after a world already existed. flecs holds live blocks
    /// from whatever allocator was in force when they were made, so swapping now would
    /// mean freeing them through the wrong one. Install before the first world.
    WorldAlreadyExists,

    /// flecs had already allocated through its own allocator before one was offered —
    /// evidence that a world was created outside this package, through the raw C API.
    /// Same hazard as above, caught through flecs's public allocation counters.
    FlecsAlreadyAllocated,

    /// `ecs_os_set_api` accepted the call but did not take the callbacks. flecs ignores
    /// the call once its OS API is initialized, and says nothing about it.
    OsApiLocked,

    /// An allocator swap was attempted while blocks from the previous one were still
    /// outstanding. Only detectable when allocation tracking is enabled.
    AllocationsOutstanding,

    /// `ecs_init` returned no world.
    WorldInitFailed,

    /// `ecs_entity_init` returned entity 0, which is flecs's failure signal.
    EntityInitFailed,

    /// `ecs_component_init` returned entity 0.
    ComponentInitFailed,

    /// `ecs_query_init` returned null. The usual cause is a malformed term.
    QueryInitFailed,

    /// `ecs_system_init` returned entity 0.
    SystemInitFailed,

    /// `ecs_observer_init` returned entity 0.
    ObserverInitFailed,

    /// `ecs_ref_init_id` handed back a zeroed ref. The entity is not alive, or it has
    /// no components at all: flecs will not make a ref for an entity that is in no
    /// table, because there is no row for it to remember.
    RefInitFailed,

    /// `ecs_write_begin` or `ecs_read_begin` refused the claim. Either the OS API has
    /// no threading — the direct-access API needs it — or another writer already holds
    /// the entity's table. flecs aborts on both unless it was built with
    /// `-Dsoft_assert`, so this is what a soft-assert build reports instead.
    RecordAccessDenied,

    /// An operation was handed an entity as a type, and flecs has no type info for it.
    /// A component registered through `World.component` always has some; a tag, or an
    /// entity that is only a name, does not.
    NotAType,

    /// A script did not parse. The `Diagnostic` says where and why; without one flecs
    /// has already written the message to its log.
    ScriptParseFailed,

    /// A parsed script did not evaluate. Typically a component the script names is not
    /// registered, or is registered without the reflection data needed to fill it in.
    ScriptEvalFailed,

    /// `ecs_script_run`, `ecs_script_run_file` or `ecs_script_update` failed. flecs
    /// folds parsing and evaluation into one return value for these, so the two cannot
    /// be told apart from the error alone.
    ScriptRunFailed,

    /// `ecs_script_init` returned entity 0: the managed script could not be loaded,
    /// usually because its file could not be read.
    ScriptInitFailed,

    /// An expression did not parse or did not evaluate. The commonest cause is a
    /// result type the expression cannot be cast to.
    ExpressionFailed,

    /// `ecs_script_vars_init` returned null.
    VariableScopeInitFailed,

    /// A script variable could not be declared: the name is already taken in this
    /// scope, or the type given for it is not a type flecs has reflection for.
    VariableDeclareFailed,

    /// A query was given more terms than the build allows. The limit is
    /// `zecs.term_count_max`, and it is a build option.
    TooManyTerms,

    /// An observer was given more events than the build allows
    /// (`zecs.event_count_max`).
    TooManyEvents,

    /// An entity was described with more ids than flecs accepts in one go. The limit is
    /// `FLECS_ID_DESC_MAX`, and it is a build option.
    TooManyIds,

    /// A stage was asked for by an index the world does not have. flecs checks this
    /// with an assert, so in a build without flecs's checks the raw call reads past
    /// the end of the stage array instead; `World.stage` compares against
    /// `ecs_get_stage_count` itself so the answer does not depend on the build.
    StageOutOfRange,

    /// `ecs_bulk_new_w_id` or `ecs_bulk_init` returned no array.
    BulkNewFailed,

    /// A bulk descriptor's arrays do not agree: one value column per id, and one
    /// entity slot per entity asked for. flecs reads all three by `count` and by the
    /// id terminator, and would run off the short one.
    BulkArrayMismatch,
    /// A JSON serializer refused. flecs reports the reason through its log rather than
    /// through the return value, so raising the log level is how to find out which of
    /// its checks failed — an unresolvable type, a component with no reflection data,
    /// an iterator that could not be walked.
    JsonSerializeFailed,

    /// A JSON parser refused: malformed input, a member naming something the world does
    /// not have, or — for `worldFromJsonFile` — a file that could not be read. flecs
    /// distinguishes these only in what it logs.
    JsonParseFailed,
    /// `ecs_pipeline_init` returned entity 0. Usually a malformed pipeline query, or an
    /// entity that already carries a pipeline.
    PipelineInitFailed,

    /// `ecs_import` returned entity 0, which flecs reports when the import function ran
    /// without registering a module entity under the name it was imported as.
    ModuleImportFailed,

    /// `ecs_metric_init` returned entity 0. flecs logs the reason: a missing or invalid
    /// kind, a member that is not a member, or a combination of kind and source it does
    /// not accept.
    MetricInitFailed,

    /// `ecs_alert_init` returned entity 0. flecs logs the reason: a query that does not
    /// match `$this`, an unresolved variable in a severity filter, or a member without
    /// warning and error ranges.
    AlertInitFailed,

    /// An alert was given more severity filters than flecs stores. The limit is four,
    /// and it is fixed in the header rather than a build option.
    TooManySeverityFilters,

    /// `ecs_app_run` returned non-zero. With the default run action that means a frame
    /// action reported an error; with a custom one it means whatever that one decided.
    AppRunFailed,

    /// `ecs_rest_server_init` returned null. It creates the server rather than binding
    /// it, so this is a resource failure rather than a port that was taken; the port is
    /// only claimed by `ecs_http_server_start`.
    RestServerInitFailed,
};
